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
    private final class WeakControllerRef {
        weak var controller: MessagesViewController?
    }

    // Transcript/live bubble instances cannot reliably expand themselves, so they
    // hand off expansion to the currently active non-transcript controller.
    private static let activeDrawerControllerRef = WeakControllerRef()

    // Lazy so transcript bubble instances never allocate these
    private lazy var coordinator = AppCoordinator()
    private lazy var receiptDraftVM = ReceiptDraftViewModel()
    private lazy var messageReceiptVM = MessageReceiptViewModel()
    private lazy var tabContextVM = TabContextViewModel()
    private lazy var hostingController = UIHostingController(rootView: RootContainerView(coordinator: coordinator, receiptDraftVM: receiptDraftVM, messageReceiptVM: messageReceiptVM, tabContextVM: tabContextVM, bus: self))
    private var hasSetupRootView = false
    private var isTranscript = false
    private var isConversationAutoSendReady = false
    private var billUpdateSessionByDocId: [String: MSSession] = [:]
    private var pendingBillUpdateByDocId: [String: (payload: LootMessagePayload, action: BillUpdateAction)] = [:]
    private var lastSentSplitSignatureByDocId: [String: String] = [:]
    private var activeBillUpdateDocId: String?
    private var activeBillUpdateSession: MSSession?

    // Content signature of the LAST warm re-broadcast we sent per docId,
    // persisted to UserDefaults. MUST be disk-backed, NOT a static/instance
    // var: iOS recreates the transcript MSMessagesAppViewController (and
    // can spin a fresh extension process) on every transcript tap, so any
    // in-memory cache is empty on the next tap and the dedup never fires
    // (device-confirmed: re-tapping an unchanged bill kept re-sending).
    // UserDefaults.standard is shared across this extension's transcript +
    // app instances and survives process recreation.
    private static let warmSigDefaultsPrefix = "loot.warmSig."
    private static func persistedWarmSig(forDocId docId: String) -> String? {
        UserDefaults.standard.string(forKey: warmSigDefaultsPrefix + docId)
    }
    private static func setPersistedWarmSig(_ sig: String, forDocId docId: String) {
        UserDefaults.standard.set(sig, forKey: warmSigDefaultsPrefix + docId)
    }
    private static func clearPersistedWarmSig(forDocId docId: String, ifEquals sig: String) {
        guard UserDefaults.standard.string(forKey: warmSigDefaultsPrefix + docId) == sig else { return }
        UserDefaults.standard.removeObject(forKey: warmSigDefaultsPrefix + docId)
    }
    /// Canonical content signature for warm-dedup. The warm path and the
    /// real send path BOTH use this so that, after we send any bill
    /// update for a docId, reopening that bubble (same content) computes
    /// the same signature and is correctly suppressed (no redundant warm
    /// re-send). Per-device UserDefaults, so other participants still warm
    /// their own session on first view (cross-sender retract preserved).
    private static func warmContentSignature(payload: LootMessagePayload, ignored: [String]?) -> String {
        // P0-5 ROOT CAUSE / FIX: the wire payload is round-tripped through
        // SharedReceiptService's `JSONSerialization … as? [String: Any]`
        // (Firestore store/merge), so its nested g/i/li objects become
        // Swift dictionaries whose JSON key order is SEEDED PER PROCESS.
        // iOS recreates the transcript VC/process on EVERY tap, so a plain
        // `JSONEncoder()` produced a different signature every tap → the
        // persisted-sig dedup could NEVER match → the warm broadcast
        // re-sent on every tap (device-confirmed via warmDUMP: identical
        // element order + values, only intra-object key order randomized).
        // `.sortedKeys` forces deterministic key order so identical
        // content hashes identically regardless of dictionary seeding.
        // Signature-only — does not change what is sent.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadSig = (try? encoder.encode(payload))?.base64EncodedString() ?? ""
        let ig = (ignored ?? []).sorted().joined(separator: ",")
        return payloadSig + "|" + ig
    }

    private func registerAsActiveDrawerControllerIfNeeded() {
        guard !isTranscript else { return }
        Self.activeDrawerControllerRef.controller = self
    }

    private func unregisterAsActiveDrawerControllerIfNeeded() {
        guard !isTranscript else { return }
        if Self.activeDrawerControllerRef.controller === self {
            Self.activeDrawerControllerRef.controller = nil
        }
    }

    private func reopenMessageIfPossible(_ message: MSMessage?) {
        guard !isTranscript,
              let message,
              let conversation = activeConversation else { return }
        saveBillUpdateAnchor(from: message)
        applyMessage(message, conversation: conversation)
    }

    private func requestExpansionFromTranscriptTap() {
        let transcriptSelectedMessage = activeConversation?.selectedMessage

        if let drawerController = Self.activeDrawerControllerRef.controller,
           drawerController !== self {
            drawerController.reopenMessageIfPossible(transcriptSelectedMessage)
            drawerController.requestPresentationStyle(.expanded)
            return
        }

        reopenMessageIfPossible(transcriptSelectedMessage)
        requestPresentationStyle(.expanded)
    }

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

        // Phase 3 step 13b: the five UIKit-bridge closures that used to be
        // assigned on `uiModel` are now methods on the `MessageBus`
        // protocol below (see extension at the bottom of this file).
        // Views inject `let bus: MessageBus = self` and call directly.

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

        isConversationAutoSendReady = false
        registerAsActiveDrawerControllerIfNeeded()
        // Anchor the bill-update session here too: when the extension launches
        // directly from a tapped bubble, iOS fires willBecomeActive but NOT
        // didSelect, so the anchor would otherwise never be set on the first
        // open and the first slot-claim update would be skipped.
        if let selectedMessage = conversation.selectedMessage {
            saveBillUpdateAnchor(from: selectedMessage)
        }
        applyMessage(conversation.selectedMessage, conversation: conversation)
        setupRootView(conversation: conversation)
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        isConversationAutoSendReady = true
        registerAsActiveDrawerControllerIfNeeded()
        flushAllPendingBillUpdatesIfNeeded(conversation: conversation)
        refreshPaymentMethodsFromFirestore()
    }

    // MARK: - Payment methods sync

    /// Pulls the local user's payment methods from Firestore and updates the
    /// UserDefaults cache if they differ. The Keychain UUID syncs across
    /// iCloud-shared devices (kSecAttrSynchronizable=true), so both phones
    /// hit the same `users/{userId}` doc — but payment methods themselves
    /// live in UserDefaults.standard which is per-device. Without this
    /// fetch-on-launch hook, phone A's saved Venmo address never appears on
    /// phone B until the user manually re-enters it.
    ///
    /// Fire-and-forget: a network failure leaves the local UserDefaults
    /// cache untouched, so the worst case is "phone B sees stale methods
    /// until next launch with connectivity," not data loss.
    private func refreshPaymentMethodsFromFirestore() {
        let userId = KeychainHelper.getOrCreateUserId()
        Task {
            do {
                guard let remote = try await TabService.shared.fetchPaymentMethods(userId: userId) else {
                    return
                }
                let local = savedPaymentMethods()
                guard remote != local else { return }
                savePaymentMethodsToDefaults(remote)
                print("[PaymentMethods] Synced from Firestore: local=\(local.count) → remote=\(remote.count)")
            } catch {
                print("[PaymentMethods] Failed to fetch from Firestore: \(error)")
            }
        }
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        isConversationAutoSendReady = false
        unregisterAsActiveDrawerControllerIfNeeded()
    }

    deinit {
        unregisterAsActiveDrawerControllerIfNeeded()
    }

    override func contentSizeThatFits(_ size: CGSize) -> CGSize {
        if isTranscript { return CGSize(width: min(size.width, 260), height: 160) }
        return super.contentSizeThatFits(size)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        guard !isTranscript else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            coordinator.isExpanded = (presentationStyle == .expanded)
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
        saveBillUpdateAnchor(from: message)
        applyMessage(message, conversation: conversation)
    }

    private func setActiveTabIfChanged(_ tab: LootTab?) {
        let currentId = tabContextVM.activeTab?.id
        let newId = tab?.id

        if currentId == newId {
            if currentId == nil, tabContextVM.activeTab == nil, tab == nil { return }
            if let current = tabContextVM.activeTab, let tab {
                // Don't downgrade rich state to a minimal stub for the same tab.
                // Settlement-card and bubble URL paths build a `LootTab.minimal`
                // (empty members) so the UI can render immediately while full
                // data loads in background. Without this guard, the stub would
                // overwrite the populated `members` and `memberIds` from the
                // live Firestore listener, leaving TabSettingsView empty and
                // the bill card showing other participants as their UUIDs
                // until the listener races back. The full-data callers
                // (cached / fetched / onTabUpdated) always populate members,
                // so they still apply and pass the idempotency check below.
                if !current.members.isEmpty && tab.members.isEmpty {
                    return
                }
                if current.name == tab.name,
                   current.colorHex == tab.colorHex,
                   current.memberIds == tab.memberIds,
                   current.receiptCount == tab.receiptCount,
                   current.status.rawValue == tab.status.rawValue {
                    return
                }
            }
        }

        tabContextVM.activeTab = tab
    }

    // MARK: - Transcript (lightweight UIKit-only path)

    @objc private func transcriptTapped() {
        // WARM DISABLED 2026-05-17 (user, drop day). The tap-context warm
        // re-broadcast fired a `conversation.send` of IDENTICAL content on
        // every participant's first view of every new content state —
        // pervasive pointless chat churn ("spams many times unless you
        // last sent it"). Hypothesis, backed by repeated lived experience
        // that Save-from-sheet retracts a sender's bubble in place: the
        // warm is UNNECESSARY — the real in-place retract happens via
        // `freshSelectedSession` (conversation.selectedMessage at Save
        // time) in sendBillUpdate, not via a pre-warmed session.
        // Disabled at the call site so the implementation stays fully
        // compiled (no dead-code warning) and revert is one line: just
        // re-enable the call below. If device testing shows claims/edits
        // now APPEND a duplicate, the warm was load-bearing → revert.
        //
        // if let conversation = activeConversation,
        //    let message = conversation.selectedMessage {
        //     broadcastTranscriptBubbleToWarmSession(from: message, conversation: conversation)
        // }
        requestExpansionFromTranscriptTap()
    }

    /// Re-broadcasts the tapped bill bubble UNCHANGED, on its own MSSession,
    /// from the synchronous transcript-tap context. This does NOT auto-claim
    /// a slot or change the payload — viewing never binds the viewer or
    /// alters the bill (the #5 fix stays intact). Its sole purpose is to keep
    /// the bubble's MSSession warm/established in iOS's send pipeline so the
    /// recipient's later EXPLICIT "Save Claims" retract (drawer → sendBillUpdate)
    /// replaces the bubble in place instead of inserting a new one. The
    /// content is identical, so this is a silent in-place refresh — no new
    /// bubble, no "claimed" summary, no participant change.
    private func broadcastTranscriptBubbleToWarmSession(from message: MSMessage,
                                                        conversation: MSConversation) {
        guard isTranscript else { return }
        guard let url = message.url,
              let decoded = LootMessageCodec.decodedInlinePayload(from: url),
              let session = message.session,
              let docId = messageDocId(from: url)
        else { return }

        // Broadcast the payload UNCHANGED — no auto-claim mutation.
        let original = decoded.payload

        let myUid = KeychainHelper.getOrCreateUserId()
        // su empty/nil ⇒ legacy payload, sender unknown ⇒ treat as
        // non-sender (the safe default keeps the warming path eligible).
        let iAmSender: Bool = {
            if let su = original.su, !su.isEmpty { return su == myUid }
            return false
        }()

        // Signature FIRST: both the P0-6 sig-gated sender-skip and the
        // P0-5 SKIP-UNCHANGED dedup need it. `.sortedKeys` inside makes it
        // process-stable (device-confirmed 2026-05-17), so a match really
        // means "live bubble == our last send for this docId".
        let warmSignature = Self.warmContentSignature(
            payload: original,
            ignored: decoded.hasIgnoredUUIDsList ? decoded.ignoredUUIDs : nil
        )
        // Per-device warm-sig baseline for this docId (set at compose, on
        // our own sends, and on prior warms). Drives both the P0-6
        // sig-gated sender-skip and the P0-5 SKIP-UNCHANGED dedup below.
        let _persisted = Self.persistedWarmSig(forDocId: docId)

        if iAmSender {
            // P0-6 fix(1): the same-sender warm-skip is correct ONLY while
            // the live bubble still reflects OUR last send (our MSSession
            // is still the live one). After a CROSS-sender retract
            // (someone else claimed/edited → replaced the bubble) the live
            // session is THEIRS; ours is stale. The per-device sig is the
            // discriminator: matches ⇒ bubble is still our last send ⇒
            // skip (no churn, genuinely warm). Differs/absent ⇒ someone
            // else changed it ⇒ we MUST warm to rebind, else our next
            // drawer action falls back to a stale session and APPENDS
            // (the locked P0-6 root cause).
            if !warmSignature.isEmpty, _persisted == warmSignature {
                print("[ConvSend] transcriptWarmSession SKIP: sender + live bubble is our last send, docId=\(docId)")
                return
            }
            print("[ConvSend] transcriptWarmSession: sender BUT bubble changed since our last send → warming to rebind, docId=\(docId)")
            // fall through to warm (rebind). The P0-5 dedup below cannot
            // skip this — sig differs by definition to reach here.
        }
        // P0-1 RESOLVED → warm-once-on-view (user, 2026-05-17, decided on
        // device evidence). NO recipient no-stake skip: a recipient
        // viewing a byItems/claim bill warms the session so their FIRST
        // claim retracts IN PLACE — avoiding the duplicate-bubble + Bryan
        // consolidation-tap churn that the no-warm-until-claim variant
        // produced in practice. The single warm is deduped to
        // once-per-content-state by the P0-5 SKIP-UNCHANGED check below
        // (per-device `.sortedKeys` sig), so a pure view is ONE silent
        // in-place refresh, never per-tap churn.

        // P0-5: warm fires once per content-state per device, then
        // SKIP-UNCHANGED on every later tap of the unchanged bill.
        if !warmSignature.isEmpty, _persisted == warmSignature {
            print("[ConvSend] transcriptWarmSession SKIP-UNCHANGED: docId=\(docId) (no payload change since last warm)")
            return
        }

        let cardImage = renderCardImage(
            receiptName: original.r.t,
            displayAmount: ReceiptDisplay.money(original.r.tot),
            participantCount: max(1, original.s.g.count),
            splitPayload: original.s,
            tabName: original.tab?.n,
            tabColorHex: original.tab?.c
        )

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: docId)]
        let preservedIgnored: [String]? = decoded.hasIgnoredUUIDsList ? decoded.ignoredUUIDs : nil
        LootMessageCodec.writePayload(
            into: &components,
            payload: original,
            ignoredUUIDs: preservedIgnored
        )

        let alternateLayout = MSMessageTemplateLayout()
        alternateLayout.image = cardImage
        let liveLayout = MSMessageLiveLayout(alternateLayout: alternateLayout)

        // No summaryText: nothing changed, so no "X updated the bill" line.
        let outgoing = MSMessage(session: session)
        outgoing.layout = liveLayout
        outgoing.url = components.url

        // Record optimistically BEFORE send so a rapid re-tap while this
        // send is in flight is also suppressed; clear on failure so a
        // failed warm can be retried. Persisted to UserDefaults so it
        // survives iOS recreating the transcript VC/process between taps.
        if !warmSignature.isEmpty {
            Self.setPersistedWarmSig(warmSignature, forDocId: docId)
        }

        print("[ConvSend] transcriptWarmSession: docId=\(docId) sessionPtr=\(ObjectIdentifier(session))")
        conversation.send(outgoing) { error in
            if let error {
                if !warmSignature.isEmpty {
                    Self.clearPersistedWarmSig(forDocId: docId, ifEquals: warmSignature)
                }
                print("[transcriptWarmSession] send failed for \(docId): \(error)")
            } else {
                print("[transcriptWarmSession] re-broadcast (unchanged) for \(docId)")
            }
        }
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
            // Find the viewer's slot to highlight + pulse
            let myUid = KeychainHelper.getOrCreateUserId()
            // The payer name MUST resolve via the same rule used in the
            // splits summary, otherwise the bubble disagrees with the
            // detail view. The old code returned the VIEWER's local name
            // when the payer slot's `n` was empty — wrong on every device
            // that isn't the payer.
            let senderName = split.payerDisplayName(meUid: myUid)
            let mySlot: Int? = split.g.firstIndex(where: { $0.uid == myUid })
            let myOwed: String? = {
                guard let slot = mySlot, owedAmounts.indices.contains(slot) else { return nil }
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
        let inviteTabId =
            comps?.queryItems?.first(where: { $0.name == "tabInvite" })?.value ??
            comps?.queryItems?.first(where: { $0.name == "tabInviteUpdate" })?.value
        if let tabId = inviteTabId,
           !tabId.isEmpty {
            let tabName = comps?.queryItems?.first(where: { $0.name == "tn" })?.value ?? "Tab"
            let tabColorHex = comps?.queryItems?.first(where: { $0.name == "tc" })?.value
            let creatorName = comps?.queryItems?.first(where: { $0.name == "cn" })?.value ?? ""
            let joinedCount = Int(comps?.queryItems?.first(where: { $0.name == "jc" })?.value ?? "") ?? 0
            let targetCount = Int(comps?.queryItems?.first(where: { $0.name == "mc" })?.value ?? "") ?? 0
            // The transcript controller is the lightweight render path
            // (no Firestore auth, no userTabs fetch) so we can't ask
            // `tabContextVM.userTabs.contains` here. `TabMembershipCache`
            // is the UserDefaults mirror of that list, kept current by
            // `TabContextViewModel.userTabs.didSet`.
            let iAmMember = TabMembershipCache.isMember(of: tabId)
            let card = TabInviteCardView(
                tabName: tabName,
                tabColorHex: tabColorHex ?? "#007AFF",
                creatorName: creatorName,
                joinedCount: joinedCount,
                targetCount: targetCount,
                showJoinPulse: true,
                iAmMember: iAmMember
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
        // Clamp Dynamic Type to .large so a large/accessibility text
        // setting can't blow out the fixed-size transcript card. Phones
        // at/below normal size are unaffected.
        let host = UIHostingController(rootView: cardView.dynamicTypeSize(...DynamicTypeSize.large))
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

    private func messageDocId(from url: URL?) -> String? {
        guard let url else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let docId = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
              !docId.isEmpty
        else { return nil }
        return docId
    }

    private func billUpdateDocId(from message: MSMessage) -> String? {
        if let docId = messageDocId(from: message.url) {
            return docId
        }
        guard let url = message.url,
              let payload = LootMessageCodec.decodedInlinePayload(from: url)?.payload else {
            return nil
        }
        return payload.r.id
    }

    private func saveBillUpdateAnchor(from message: MSMessage) {
        let extractedDocId = billUpdateDocId(from: message)
        let hasSession = message.session != nil
        guard let docId = extractedDocId,
              let session = message.session else {
            print("[BillUpdate] saveBillUpdateAnchor SKIP: docId=\(extractedDocId ?? "nil") hasSession=\(hasSession)")
            return
        }
        let previousDocId = activeBillUpdateDocId
        activeBillUpdateDocId = docId
        activeBillUpdateSession = session
        billUpdateSessionByDocId[docId] = session
        print("[BillUpdate] saveBillUpdateAnchor: docId=\(docId) (was \(previousDocId ?? "nil")) sessionPtr=\(ObjectIdentifier(session))")
    }

    private func splitSignature(for split: SplitPayload) -> String {
        guard let data = try? JSONEncoder().encode(split) else { return "" }
        return data.base64EncodedString()
    }

    private func shouldAdoptFetchedPayload(_ fetched: LootMessagePayload, for docId: String) -> Bool {
        guard messageReceiptVM.openedMessageDocId == docId else { return true }
        guard let current = messageReceiptVM.openedMessagePayload else { return true }

        let fetchedSignature = splitSignature(for: fetched.s)
        let currentSignature = splitSignature(for: current.s)
        guard fetchedSignature != currentSignature else { return true }

        let myUid = KeychainHelper.getOrCreateUserId()
        let currentHasClaim = current.s.g.contains(where: { $0.uid == myUid })
        let fetchedHasClaim = fetched.s.g.contains(where: { $0.uid == myUid })

        // Ignore stale Firestore reads that would undo a local slot claim we just applied.
        if currentHasClaim && !fetchedHasClaim {
            print("[applyMessage] Ignoring stale fetched payload for \(docId); local claim is newer")
            return false
        }

        // Same race for OTHER participants' claims. The inline payload baked
        // into a freshly-broadcast bubble (e.g. a "joined a bill" update from
        // B) carries their claim immediately, but B's drawer-side
        // persistSplit Firestore write may still be in flight. If our current
        // view has uids that the fetched payload lacks, the fetch is stale
        // and would visually undo a join that just landed via the bubble's
        // session-replace — reverting B's name to "Guest N" half a second
        // after we first rendered it correctly.
        let currentUids = Set(current.s.g.compactMap { g -> String? in
            guard let u = g.uid, !u.isEmpty else { return nil }
            return u
        })
        let fetchedUids = Set(fetched.s.g.compactMap { g -> String? in
            guard let u = g.uid, !u.isEmpty else { return nil }
            return u
        })
        if !currentUids.subtracting(fetchedUids).isEmpty {
            print("[applyMessage] Ignoring stale fetched payload for \(docId); local has uids fetched lacks")
            return false
        }

        return true
    }

    private func bindBillUpdateAnchor(from message: MSMessage, docId: String, conversation: MSConversation) {
        guard activeBillUpdateDocId == docId,
              let session = activeBillUpdateSession else {
            print("[BillUpdate] bindBillUpdateAnchor MISMATCH: incomingDocId=\(docId) activeBillUpdateDocId=\(activeBillUpdateDocId ?? "nil") hasSession=\(activeBillUpdateSession != nil)")
            return
        }
        billUpdateSessionByDocId[docId] = session
        print("[BillUpdate] bindBillUpdateAnchor: docId=\(docId) sessionPtr=\(ObjectIdentifier(session))")
        flushPendingBillUpdateIfNeeded(for: docId, conversation: conversation)
    }

    private func flushPendingBillUpdateIfNeeded(for docId: String, conversation: MSConversation) {
        guard let pending = pendingBillUpdateByDocId.removeValue(forKey: docId) else { return }
        sendBillUpdate(payload: pending.payload, docId: docId, action: pending.action, conversation: conversation)
    }

    private func flushAllPendingBillUpdatesIfNeeded(conversation: MSConversation) {
        let pending = pendingBillUpdateByDocId
        pendingBillUpdateByDocId.removeAll()
        for (docId, entry) in pending {
            sendBillUpdate(payload: entry.payload, docId: docId, action: entry.action, conversation: conversation)
        }
    }

    private func sendBillUpdate(payload: LootMessagePayload, docId: String, action: BillUpdateAction, conversation: MSConversation) {
        let signature = splitSignature(for: payload.s)
        let perDocSession = billUpdateSessionByDocId[docId]

        // Prefer the FRESHEST session — `conversation.selectedMessage` is the
        // bubble iOS currently considers selected. iOS rebuilds MSMessage
        // objects (with new MSSession instances) on every transcript re-render,
        // and after our own conversation.send fires it cascades 5+ more
        // didSelect/willBecomeActive events with new session pointers each
        // time. The session anchored at first-tap goes stale within
        // milliseconds. Using the fresh selectedMessage session matches what
        // `broadcastTranscriptAutojoinIfPossible` does — that path retracts
        // bubbles in place reliably; this one didn't, until now.
        let freshSelectedSession: MSSession? = {
            guard let selected = conversation.selectedMessage,
                  let selectedUrl = selected.url,
                  messageDocId(from: selectedUrl) == docId,
                  let session = selected.session else {
                return nil
            }
            return session
        }()

        let myUid = KeychainHelper.getOrCreateUserId()
        let senderUid = payload.su
        let iAmSender = (senderUid == myUid)

        print("[BillUpdate] sendBillUpdate ENTER: docId=\(docId) action=\(action) activeDocId=\(activeBillUpdateDocId ?? "nil") activeSessionPtr=\(activeBillUpdateSession.map { ObjectIdentifier($0).hashValue.description } ?? "nil") perDocSessionPtr=\(perDocSession.map { ObjectIdentifier($0).hashValue.description } ?? "nil") freshSelectedSessionPtr=\(freshSelectedSession.map { ObjectIdentifier($0).hashValue.description } ?? "nil") autoSendReady=\(isConversationAutoSendReady) senderUid=\(senderUid ?? "nil") myUid=\(myUid) iAmSender=\(iAmSender)")

        // NOTE on cross-sender behavior: when a non-original-sender taps
        // someone else's bill bubble and triggers `conversation.send` on the
        // attached MSSession, iMessage RETRACTS the original bubble and
        // inserts a new one authored by the local participant. The
        // attribution flips, but the bubble count stays at one — which is
        // exactly the behavior we want for cross-sender edits / removeFromTab.
        // An earlier guard short-circuited this path on the assumption that
        // it produced duplicate bubbles; device testing didn't confirm that,
        // so the broadcast now runs for everyone. If duplicates ever DO
        // appear cross-sender, narrow the skip to the specific failure mode
        // (don't blanket-skip again) and capture a repro before doing so.

        if !signature.isEmpty,
           !action.bypassesSplitSignatureDedup,
           lastSentSplitSignatureByDocId[docId] == signature {
            print("[BillUpdate] sendBillUpdate DEDUP: same signature already sent for docId=\(docId)")
            return
        }

        guard isConversationAutoSendReady else {
            pendingBillUpdateByDocId[docId] = (payload, action)
            print("[BillUpdate] sendBillUpdate DEFER: queued for docId=\(docId) until conversation auto-send ready")
            return
        }

        // Fresh session from selectedMessage wins over anchored/per-doc.
        if let session = freshSelectedSession {
            print("[BillUpdate] sendBillUpdate FRESH-SELECTED: sending via sessionPtr=\(ObjectIdentifier(session))")
            sendBillUpdateMessage(
                payload: payload,
                docId: docId,
                signature: signature,
                session: session,
                action: action,
                conversation: conversation
            )
            return
        }

        if activeBillUpdateDocId == docId, let anchoredSession = activeBillUpdateSession {
            print("[BillUpdate] sendBillUpdate ANCHOR-MATCH: sending via activeSessionPtr=\(ObjectIdentifier(anchoredSession))")
            sendBillUpdateMessage(
                payload: payload,
                docId: docId,
                signature: signature,
                session: anchoredSession,
                action: action,
                conversation: conversation
            )
            return
        }

        if let perDocSession {
            print("[BillUpdate] sendBillUpdate FALLBACK-PER-DOC: active anchor is for \(activeBillUpdateDocId ?? "nil") but per-doc session exists for \(docId), sending via perDocSessionPtr=\(ObjectIdentifier(perDocSession))")
            sendBillUpdateMessage(
                payload: payload,
                docId: docId,
                signature: signature,
                session: perDocSession,
                action: action,
                conversation: conversation
            )
            return
        }

        print("[BillUpdate] sendBillUpdate SKIP: no anchored session for docId=\(docId) (activeBillUpdateDocId=\(activeBillUpdateDocId ?? "nil"))")
    }

    private func sendBillUpdateMessage(
        payload: LootMessagePayload,
        docId: String,
        signature: String,
        session: MSSession,
        action: BillUpdateAction,
        conversation: MSConversation
    ) {
        let splitPayload = payload.s
        let participantCount = max(1, splitPayload.g.count)

        let cardImage = renderCardImage(
            receiptName: payload.r.t,
            displayAmount: ReceiptDisplay.money(payload.r.tot),
            participantCount: participantCount,
            splitPayload: splitPayload,
            tabName: payload.tab?.n,
            tabColorHex: payload.tab?.c
        )

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: docId)]
        let ignoredToWrite: [String]? = messageReceiptVM.hasIgnoredUUIDsList(for: docId)
            ? messageReceiptVM.ignoredUUIDs(for: docId)
            : nil
        LootMessageCodec.writePayload(
            into: &components,
            payload: payload,
            ignoredUUIDs: ignoredToWrite
        )

        // We're sending this exact content NOW, so record it as the warm
        // signature for this docId on THIS device. Effect: after you
        // claim/edit/leave, reopening that bubble (same content) is
        // suppressed by the warm dedup instead of re-sending. Other
        // participants have their own per-device UserDefaults, so they
        // still warm their session on first view (cross-sender retract
        // preserved).
        Self.setPersistedWarmSig(
            Self.warmContentSignature(payload: payload, ignored: ignoredToWrite),
            forDocId: docId
        )

        if !signature.isEmpty {
            lastSentSplitSignatureByDocId[docId] = signature
        }

        let alternateLayout = MSMessageTemplateLayout()
        alternateLayout.image = cardImage
        let liveLayout = MSMessageLiveLayout(alternateLayout: alternateLayout)

        let message = MSMessage(session: session)
        message.layout = liveLayout
        message.url = components.url
        message.summaryText = action.summaryText

        print("[BillUpdate] sendBillUpdateMessage: docId=\(docId) sessionPtr=\(ObjectIdentifier(session)) layout=liveLayout url=\(components.url?.absoluteString.prefix(80) ?? "nil")")

        conversation.send(message) { [weak self] error in
            if let error {
                if !signature.isEmpty, self?.lastSentSplitSignatureByDocId[docId] == signature {
                    self?.lastSentSplitSignatureByDocId.removeValue(forKey: docId)
                }
                print("[BillUpdate] sendBillUpdateMessage FAILED: docId=\(docId) error=\(error)")
            } else {
                print("[BillUpdate] sendBillUpdateMessage COMPLETE: docId=\(docId) (no error — bubble should have replaced in place if session was valid)")
            }
        }
    }

    private func applyMessage(_ message: MSMessage?, conversation: MSConversation) {
        // expansion state
        coordinator.isExpanded = (presentationStyle == .expanded)

        guard let msg = message, let url = msg.url else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Version gate: if the sender's major version is higher than ours,
        // the message requires features we don't have yet.
        if let mvString = comps?.queryItems?.first(where: { $0.name == LootVersion.urlParamName })?.value,
           let senderMajor = Int(mvString),
           senderMajor > LootVersion.major {
            requestPresentationStyle(.expanded)
            coordinator.currentScreen = .updateRequired
            return
        }

        let pendingRequest = pendingPayRequest(from: comps)
        messageReceiptVM.pendingPayRequest = pendingRequest
        if pendingRequest != nil {
            requestPresentationStyle(.expanded)
        }

        // New path: Firestore doc ID
        if let docId = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
           !docId.isEmpty {
            bindBillUpdateAnchor(from: msg, docId: docId, conversation: conversation)

            // Extract inline fallback payload embedded at send time.
            // Present it immediately while Firestore refreshes in the background.
            let decodedInline = LootMessageCodec.decodedInlinePayload(from: url)
            let inlinePayload = decodedInline?.payload

            if let decodedInline {
                messageReceiptVM.setInlineIgnoredState(
                    ignoredUUIDs: decodedInline.ignoredUUIDs,
                    hasList: decodedInline.hasIgnoredUUIDsList,
                    for: docId
                )
                messageReceiptVM.openedMessagePayload = decodedInline.payload
                receiptDraftVM.currentReceipt = decodedInline.payload.toReceiptDisplay()
                messageReceiptVM.messageLoadingState = .loaded(decodedInline.payload)
            } else {
                // No local payload available, so fall back to the loading state.
                messageReceiptVM.openedMessagePayload = nil
                messageReceiptVM.messageLoadingState = .loading
                messageReceiptVM.setInlineIgnoredState(ignoredUUIDs: [], hasList: false, for: docId)
            }

            messageReceiptVM.openedMessageDocId = docId
            coordinator.currentScreen = .messageViewer

            Task { @MainActor in
                do {
                    let (payload, captureImage) = try await SharedReceiptService.shared.fetch(id: docId)
                    guard shouldAdoptFetchedPayload(payload, for: docId) else { return }
                    messageReceiptVM.openedMessagePayload = payload
                    receiptDraftVM.currentReceipt = payload.toReceiptDisplay()
                    if let captureImage {
                        receiptDraftVM.scanImageCropped = captureImage
                    }
                    messageReceiptVM.messageLoadingState = .loaded(payload)
                    if let tabData = payload.tab { await applyTabData(tabData) }
                } catch {
                    print("[applyMessage] Firestore fetch failed: \(error)")
                    if let inline = inlinePayload {
                        // Use the baked-in payload so the receipt opens immediately,
                        // even without a network connection.
                        print("[applyMessage] Falling back to inline payload for \(docId)")
                        messageReceiptVM.openedMessagePayload = inline
                        receiptDraftVM.currentReceipt = inline.toReceiptDisplay()
                        messageReceiptVM.messageLoadingState = .loaded(inline)
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
                        messageReceiptVM.messageLoadingState = .failed(error)
                    }
                }
            }
            return
        }

        // Tab invite path: ?tabInvite=<tabId> or ?tabInviteUpdate=<tabId>
        let inviteTabId =
            comps?.queryItems?.first(where: { $0.name == "tabInvite" })?.value ??
            comps?.queryItems?.first(where: { $0.name == "tabInviteUpdate" })?.value
        if let tabId = inviteTabId,
           !tabId.isEmpty {
            // Navigate immediately so the screen change is synchronous —
            // avoids race with didTransition when re-tapping the same invite.
            requestPresentationStyle(.expanded)
            tabContextVM.pendingTabInviteId = tabId
            coordinator.currentScreen = .joinTab
            // Bump the nonce so re-tapping the SAME invite while JoinTabView
            // is already on screen triggers a fresh fetch — without this,
            // both `pendingTabInviteId` and `currentScreen` are unchanged
            // and SwiftUI's `.task(id:)` doesn't re-fire.
            tabContextVM.pendingTabInviteRefreshNonce &+= 1
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
                if let cached = tabContextVM.userTabs.first(where: { $0.id == tabId }) {
                    setActiveTabIfChanged(cached)
                } else if let full = try? await TabService.shared.fetchTab(id: tabId) {
                    setActiveTabIfChanged(full)
                }
            }
            coordinator.currentScreen = .tabview
            return
        }

        // Legacy path: inline payload
        if let decodedInline = LootMessageCodec.decodedInlinePayload(from: url) {
            let billId = decodedInline.payload.r.id
            bindBillUpdateAnchor(from: msg, docId: billId, conversation: conversation)
            messageReceiptVM.setInlineIgnoredState(
                ignoredUUIDs: decodedInline.ignoredUUIDs,
                hasList: decodedInline.hasIgnoredUUIDsList,
                for: billId
            )
            let payload = decodedInline.payload
            messageReceiptVM.openedMessagePayload = payload
            messageReceiptVM.openedMessageDocId = billId
            receiptDraftVM.currentReceipt = payload.toReceiptDisplay()
            coordinator.currentScreen = .messageViewer
            if let tabData = payload.tab { Task { @MainActor in await self.applyTabData(tabData) } }
        }
    }

    private func applyTabData(_ tabData: TabPayload) async {
        let minimal = LootTab.minimal(id: tabData.id, name: tabData.n, colorHex: tabData.c)

        // Only assign receiptTab when activeTab doesn't already cover this
        // tab. This is the ONLY @Published mutation that fires differently
        // between tab and non-tab bills in the applyMessage flow — for the
        // SENDER of a tab bill, activeTab already points at the same tab,
        // so receiptTab is redundant. Setting it anyway fires a SwiftUI
        // re-render across the drawer view tree, and that re-render
        // (during the bubble's lifecycle, between tap-time and edit-time)
        // appears to be what invalidates iOS's cached MSSession reference
        // for the bubble — causing subsequent edit broadcasts to silently
        // append a new bubble instead of retracting in place. Skipping the
        // assignment when redundant collapses the tab-edit workflow into
        // exactly the same shape as non-tab. All readers of receiptTab
        // (SplitsSummaryView.associatedTab, settlement URL builders) fall
        // back to activeTab when receiptTab is nil, so visual styling is
        // preserved.
        if tabContextVM.activeTab?.id != tabData.id {
            tabContextVM.receiptTab = minimal
        }

        // No switch needed if the receipt belongs to the already-active tab
        guard tabContextVM.activeTab?.id != tabData.id else { return }

        let myId = KeychainHelper.getOrCreateUserId()

        // Check local cache first (avoids a network round-trip)
        if let cached = tabContextVM.userTabs.first(where: { $0.id == tabData.id }) {
            if cached.memberIds.contains(myId) {
                setActiveTabIfChanged(cached)
                if let ck = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(cached, for: ck)
                }
            }
            // Non-member: SplitsSummaryView's locked screen handles the UI
            return
        }

        // Not in local tabs — fetch to verify membership
        if let tab = try? await TabService.shared.fetchTab(id: tabData.id) {
            if tab.memberIds.contains(myId) {
                setActiveTabIfChanged(tab)
                if let ck = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(tab, for: ck)
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
        tabContextVM.localParticipantId = localId

        // Compute conversation key from ALL participant identifiers (local + remote)
        var identifiers = conversation.remoteParticipantIdentifiers.map { $0.uuidString }
        identifiers.append(localId)
        tabContextVM.conversationKey = TabService.conversationKey(from: identifiers)

        // Try to load active tab for this conversation and sync user doc
        if let convKey = tabContextVM.conversationKey {
            // Instant: restore from local cache so the tab shows immediately
            if coordinator.currentScreen != .joinTab {
                setActiveTabIfChanged(tabContextVM.cachedTab(for: convKey))
            }

            Task { @MainActor in
                // Only restore the conversation's tab if we're not in the middle
                // of a join flow — otherwise this would overwrite the tab the user
                // is about to join / just joined.
                if coordinator.currentScreen != .joinTab {
                    let myId = KeychainHelper.getOrCreateUserId()
                    do {
                        let tab = try await TabService.shared.getTabForConversation(conversationKey: convKey)

                        // Store conversation member IDs for tab relevance sorting,
                        // regardless of whether the current user is still a member.
                        if let t = tab {
                            tabContextVM.conversationMemberIds = Set(t.memberIds)
                        } else {
                            tabContextVM.conversationMemberIds = []
                        }

                        // Only set as active if this user is still an active member
                        // (guards against tabs the user has left).
                        if let t = tab, t.memberIds.contains(myId) {
                            setActiveTabIfChanged(t)
                            tabContextVM.cacheTab(t, for: convKey)
                        } else {
                            setActiveTabIfChanged(nil)
                            tabContextVM.cacheTab(nil, for: convKey)
                        }
                    } catch {
                        // Keep the cached tab on transient lookup failures instead of
                        // silently disassociating the conversation.
                        print("[setupRootView] getTabForConversation failed: \(error)")
                    }
                }
                do {
                    tabContextVM.userTabs = try await TabService.shared.fetchUserTabs()
                } catch {
                    print("[setupRootView] fetchUserTabs failed: \(error)")
                    tabContextVM.userTabs = []
                }

                // If user closed Loot to retrieve their Zelle QR code, route them back
                // to Payment Methods as soon as the app reopens.
                if UserDefaults.standard.bool(forKey: DefaultsKeys.pendingReturnToPaymentMethods) {
                    UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingReturnToPaymentMethods)
                    coordinator.currentScreen = .paymentMethods
                }

                // Ensure user doc exists and display name stays in sync
                let displayName = myDisplayNameFromDefaults()
                if !displayName.isEmpty {
                    try? await TabService.shared.createOrUpdateUser(
                        userId: KeychainHelper.getOrCreateUserId(),
                        displayName: displayName
                    )
                }

                // Retry any settlement whose Firestore write failed or
                // was cut off by extension teardown last session. The
                // outbox is the durability layer between "user was
                // handed off to the payment app" and "tab ledger
                // recorded it".
                await SettlementOutbox.flush()
            }
        }

        // Only create the SwiftUI root view once. Re-creating it on every
        // willBecomeActive causes layout glitches when the extension is simply
        // collapsed (tap text field) and re-opened — the new view tree renders
        // while the container is still animating, producing an offset.
        // State updates above still propagate via the four VMs / coordinator.
        guard !hasSetupRootView else { return }
        hasSetupRootView = true

        hostingController.rootView = RootContainerView(
            coordinator: coordinator,
            receiptDraftVM: receiptDraftVM,
            messageReceiptVM: messageReceiptVM,
            tabContextVM: tabContextVM,
            bus: self,
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
            },
            onSendTabInviteUpdate: { [weak self] tabId in
                self?.sendTabInviteUpdate(tabId: tabId)
            }
        )
    }
    
    // MARK: - Shared helpers

    /// Renders any SwiftUI view into a UIImage at the given size.
    /// Dynamic Type is clamped to `.large` (the standard non-accessibility
    /// size): the transcript card is a fixed-size chat graphic, so a
    /// device's accessibility text setting must not blow it out. Phones
    /// at/below normal size are unaffected; only large/accessibility
    /// sizes are clamped down. (Receipt detail in the drawer still
    /// respects the user's accessibility size.)
    private func renderView<T: View>(_ view: T, size: CGSize) -> UIImage {
        let hosting = UIHostingController(rootView: view.dynamicTypeSize(...DynamicTypeSize.large))
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
        var items: [URLQueryItem] = [
            URLQueryItem(name: LootVersion.urlParamName, value: String(LootVersion.major))
        ]
        if let tab, let tabId = tab.id {
            items.append(URLQueryItem(name: "tabId", value: tabId))
            items.append(URLQueryItem(name: "tn", value: tab.name))
            if let hex = tab.colorHex, !hex.isEmpty { items.append(URLQueryItem(name: "tc", value: hex)) }
        }
        components.queryItems = items
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
        let components = lootURLComponents(tab: tabContextVM.receiptTab ?? tabContextVM.activeTab)

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url
        message.summaryText = "sent a payment"

        print("[ConvSend] sendSettlementMessage: NEW SESSION (will appear as new bubble) summaryText=\"sent a payment\"")
        conversation.send(message) { error in
            if let error { print("[MessagesViewController] sendSettlementMessage error: \(error)") }
        }
    }

    /// Apple Pay flow: send the settlement card to the chat. The "now open
    /// the Apple Cash drawer" hint is shown by `TabPayNowSheet` after the
    /// user taps Apple Pay — keeping it in-extension means it never leaks
    /// to other participants and we don't have to rely on MSSession
    /// replacement, which doesn't reliably carry through `insert`.
    func sendApplePayHandoff(fromName: String, toName: String,
                             amountCents: Int, tabColorHex: String?) {
        guard let conversation = activeConversation else { return }

        let card = SettlementCardView(fromName: fromName, toName: toName,
                                      amountCents: amountCents,
                                      methodName: "Apple Cash",
                                      tabColorHex: tabColorHex)
        let cardImage = renderView(card, size: CGSize(width: 260, height: 60))
        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = lootURLComponents(tab: tabContextVM.receiptTab ?? tabContextVM.activeTab).url
        message.summaryText = "sent a payment"
        print("[ConvSend] sendApplePayHandoff: NEW SESSION (will appear as new bubble) summaryText=\"sent a payment\"")
        conversation.send(message) { error in
            if let error { print("[MessagesViewController] sendApplePayHandoff send error: \(error)") }
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
        var components = lootURLComponents(tab: tabContextVM.receiptTab ?? tabContextVM.activeTab)
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
        message.summaryText = "requested a payment"

        print("[ConvSend] sendRequestMessage: NEW SESSION (will appear as new bubble) summaryText=\"requested a payment\"")
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

        // Same resolver as applyMessage / SplitsSummaryView — the baked
        // card image must agree with both, otherwise the bubble's
        // alternate-layout image disagrees with the live BillCardView.
        let payerDisplayName = splitPayload.payerDisplayName(
            meUid: KeychainHelper.getOrCreateUserId()
        )

        let card = BillCardView(
            receiptName: receiptName,
            displayAmount: displayAmount,
            displayName: payerDisplayName,
            splitLabel: splitLabelFromMode(splitPayload.m),
            owedAmounts: owedAmounts.isEmpty ? nil : owedAmounts,  // Only pass if non-empty
            totalCents: splitPayload.tot,
            tabName: tabName,
            tabColorHex: tabColorHex
        )

        // Render at BillCardView's TRUE intrinsic size (260×160, fixed by
        // its own `.frame(width: 260, height: 160)`). A 250×150 canvas is
        // SMALLER than the card, so `renderView`'s drawHierarchy clips the
        // centered card ~5pt on every edge — that's the L/R bubble clip
        // (P1-7), a canvas-size mismatch, NOT a Dynamic-Type / text-size
        // issue. iOS then scales this correctly-sized image to the bubble
        // width preserving aspect, so nothing is lost. Matches the 260×160
        // render used by the other card path in this file.
        return renderView(card, size: CGSize(width: 260, height: 160))
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
        let fallbackTotalCents = stringToCents(amount)
        let receiptDisplay = receiptDraftVM.currentReceipt ?? ReceiptDisplay(
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

        let draft = receiptDraftVM.currentSplitDraft
        let splitPayload = SplitPayload.from(draft: draft,
                                             participantCount: participantCount,
                                             totalCents: receiptDisplay.totalCents)

        let receiptPayload = ReceiptPayload.from(receipt: receiptDisplay, split: splitPayload)

        var payload = LootMessagePayload(r: receiptPayload, s: splitPayload, tid: tabContextVM.activeTab?.id, su: KeychainHelper.getOrCreateUserId())
        if let activeTab = tabContextVM.activeTab, let tabId = activeTab.id {
            payload.tab = TabPayload(id: tabId, n: activeTab.name, c: activeTab.colorHex)
        }

        // Capture scan image before async block (will be nil for manual receipts)
        let captureImage = receiptDraftVM.scanImageCropped ?? receiptDraftVM.scanImageOriginal
        let cardImage = renderCardImage(
            receiptName: receiptDisplay.title,
            displayAmount: ReceiptDisplay.money(receiptDisplay.totalCents),
            participantCount: participantCount,
            splitPayload: splitPayload,
            tabName: tabContextVM.activeTab?.name,
            tabColorHex: tabContextVM.activeTab?.colorHex
        )

        // Pre-generate a Firestore doc ID (local, no network)
        let docId = SharedReceiptService.shared.generateDocId()
        messageReceiptVM.setInlineIgnoredState(ignoredUUIDs: [], hasList: true, for: docId)

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: docId)]
        let composeIgnored = messageReceiptVM.ignoredUUIDs(for: docId)
        LootMessageCodec.writePayload(
            into: &components,
            payload: payload,
            ignoredUUIDs: composeIgnored
        )

        // P0-6 fix(1) prerequisite: record the warm-sig BASELINE for this
        // docId on the SENDER's device at compose time. Without this the
        // sender has no per-device sig for a bill they composed, so the
        // sig-gated sender-skip in broadcastTranscriptBubbleToWarmSession
        // computes match=false and re-warms the sender's own untouched
        // bill (regression). With the baseline: reopening your own
        // unchanged bill → match=true → SKIP (no churn); after a
        // cross-sender retract the live content differs → match=false →
        // warm-to-rebind. Same form as sendBillUpdateMessage's record.
        Self.setPersistedWarmSig(
            Self.warmContentSignature(payload: payload, ignored: composeIgnored),
            forDocId: docId
        )

        let alternateLayout = MSMessageTemplateLayout()
        alternateLayout.image = cardImage
        let liveLayout = MSMessageLiveLayout(alternateLayout: alternateLayout)

        let message = MSMessage(session: MSSession())
        message.layout = liveLayout
        message.url = components.url
        message.summaryText = "shared a bill"

        print("[ConvSend] sendBillMessage: NEW SESSION (will appear as new bubble) docId=\(docId) summaryText=\"shared a bill\"")
        conversation.send(message) { error in
            if let error { print("[sendBillMessage] Failed to send bill message: \(error)") }
        }

        requestPresentationStyle(.compact)

        Task {
            do {
                try await SharedReceiptService.shared.upload(payload, captureImage: captureImage, docId: docId)
                print("[sendBillMessage] Uploaded to Firestore: \(docId)")

                if let tabId = payload.tid {
                    if let refreshed = try await TabService.shared.syncTabDerivedState(tabId: tabId) {
                        await MainActor.run {
                            self.tabContextVM.activeTab = refreshed
                        }
                        if let ck = self.tabContextVM.conversationKey {
                            tabContextVM.cacheTab(refreshed, for: ck)
                        }
                    }
                    print("[sendBillMessage] Synced tab aggregates for \(tabId)")
                }
            } catch {
                print("[sendBillMessage] Firestore upload failed: \(error)")
            }
        }
    }

    func sendBillUpdate(payload: LootMessagePayload, docId: String, action: BillUpdateAction) {
        guard let conversation = activeConversation else { return }
        sendBillUpdate(payload: payload, docId: docId, action: action, conversation: conversation)
    }

    private func sendTabInviteMessage(
        tabName: String,
        tabColorHex: String,
        tabId: String,
        joinedCount: Int,
        queryItemName: String,
        useSelectedMessageSession: Bool = false
    ) {
        guard let conversation = activeConversation else { return }

        let targetCount = max(1, conversation.remoteParticipantIdentifiers.count + 1)
        let creatorName = myDisplayNameFromDefaults()
        let card = TabInviteCardView(
            tabName: tabName,
            tabColorHex: tabColorHex,
            creatorName: creatorName,
            joinedCount: joinedCount,
            targetCount: targetCount
        )
        let cardImage = renderView(card, size: CGSize(width: 260, height: 160))

        // Encode counts + creator name on the URL so the live-layout
        // transcript bubble can show real values instead of the
        // hardcoded "0/1 joined" placeholder. Re-broadcasts via
        // sendTabInviteUpdate carry refreshed values, so the bubble
        // updates in place when someone joins.
        var components = lootURLComponents()
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: queryItemName, value: tabId),
            URLQueryItem(name: "tn", value: tabName),
            URLQueryItem(name: "tc", value: tabColorHex),
            URLQueryItem(name: "jc", value: String(joinedCount)),
            URLQueryItem(name: "mc", value: String(targetCount)),
            URLQueryItem(name: "cn", value: creatorName)
        ]
        components.queryItems = queryItems

        let session: MSSession
        if useSelectedMessageSession {
            session = conversation.selectedMessage?.session ?? MSSession()
        } else {
            session = MSSession()
        }
        // MSMessageLiveLayout (with the template as alternate) so iOS spawns a
        // transcript-mode MessagesViewController per bubble. That controller's
        // UITapGestureRecognizer fires on every tap — including re-taps of the
        // same invite — and forwards to the drawer via
        // `requestExpansionFromTranscriptTap`. Plain template layouts don't
        // get this routing (iOS dedupes same-message taps natively), which is
        // why a second tap on the same invite was a no-op.
        let alternateLayout = MSMessageTemplateLayout()
        alternateLayout.image = cardImage
        let liveLayout = MSMessageLiveLayout(alternateLayout: alternateLayout)

        let message = MSMessage(session: session)
        message.layout = liveLayout
        message.url = components.url
        // queryItemName == "tabInviteUpdate" is the same-session retract+replace
        // path used when someone joins an existing tab; the original "tabInvite"
        // name is the brand-new invite send.
        message.summaryText = (queryItemName == "tabInviteUpdate") ? "joined a tab" : "invited you to a tab"

        print("[ConvSend] sendTabInvite: queryItem=\(queryItemName) sessionPtr=\(ObjectIdentifier(session)) usedSelectedSession=\(useSelectedMessageSession)")
        conversation.send(message) { error in
            if let error { print("[\(queryItemName)] send failed: \(error)") }
        }
    }

    func sendTabInvite(tabName: String, tabColorHex: String, tabId: String) {
        let joinedCount = max(1, tabContextVM.activeTab?.members.filter(\.isActive).count ?? 1)
        sendTabInviteMessage(
            tabName: tabName,
            tabColorHex: tabColorHex,
            tabId: tabId,
            joinedCount: joinedCount,
            queryItemName: "tabInvite"
        )

        requestPresentationStyle(.compact)
    }

    func sendTabInviteUpdate(tabId: String) {
        guard !tabId.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                guard let refreshedTab = try await TabService.shared.fetchTab(id: tabId) else {
                    print("[tabInviteUpdate] Tab not found: \(tabId)")
                    return
                }

                setActiveTabIfChanged(refreshedTab)
                tabContextVM.conversationMemberIds = Set(refreshedTab.memberIds)
                if let index = tabContextVM.userTabs.firstIndex(where: { $0.id == refreshedTab.id }) {
                    tabContextVM.userTabs[index] = refreshedTab
                } else {
                    tabContextVM.userTabs.append(refreshedTab)
                }

                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(refreshedTab, for: convKey)
                    do {
                        try await TabService.shared.associateConversation(
                            tabId: tabId,
                            conversationKey: convKey
                        )
                    } catch {
                        print("[tabInviteUpdate] associateConversation failed: \(error)")
                    }
                }

                let joinedCount = max(1, refreshedTab.members.filter(\.isActive).count)
                let tabColor = refreshedTab.colorHex ?? TabColorOptions.defaultHex
                sendTabInviteMessage(
                    tabName: refreshedTab.name,
                    tabColorHex: tabColor,
                    tabId: tabId,
                    joinedCount: joinedCount,
                    queryItemName: "tabInviteUpdate",
                    useSelectedMessageSession: true
                )
            } catch {
                print("[tabInviteUpdate] Failed to refresh tab \(tabId): \(error)")
            }
        }
    }

}

// MARK: - MessageBus conformance (Phase 3 step 13b)

extension MessagesViewController: MessageBus {
    func openInSafari(_ url: URL) {
        // iMessage extensions can't use `UIApplication.shared` directly —
        // it's marked `@available(iOSApplicationExtension, unavailable)`.
        // The legacy `openURL:` selector has been force-returning false
        // since iOS 13, so the old KVC + perform-selector trick is dead.
        // We need a UIApplication INSTANCE and the modern
        // `open(_:options:completionHandler:)` method on it.
        //
        // Walk the responder chain (cleanest, no private API). Falls
        // back to NSClassFromString + KVC if the chain doesn't reach
        // UIApplication, and `extensionContext.open` as a last resort
        // (works for https:// only, not custom schemes).
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }

        if let appClass = NSClassFromString("UIApplication"),
           let app = appClass.value(forKey: "sharedApplication") as? UIApplication {
            app.open(url, options: [:], completionHandler: nil)
            return
        }

        extensionContext?.open(url, completionHandler: nil)
    }

    func sendSettlementCard(fromName: String, toName: String, amountCents: Int, methodName: String, tabColorHex: String?) {
        sendSettlementMessage(fromName: fromName, toName: toName,
                              amountCents: amountCents, methodName: methodName,
                              tabColorHex: tabColorHex)
    }

    // The 4-arg overload routes to `sendApplePayHandoff(fromName:toName:amountCents:tabColorHex:)`
    // already defined elsewhere; the protocol method shape matches the existing one
    // by name, so no shim needed — the conformance is automatic.

    func sendRequestCard(creditorName: String, debtorName: String, amountCents: Int, tabColorHex: String?, metadata: RequestCardMetadata?) {
        sendRequestMessage(creditorName: creditorName, debtorName: debtorName,
                           amountCents: amountCents, tabColorHex: tabColorHex,
                           metadata: metadata)
    }

    // Same for `sendBillUpdate(payload:docId:action:)` — the 3-arg version
    // already exists, satisfies the protocol automatically.
}
