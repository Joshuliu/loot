//
//  SplitsSummaryView.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI
import UIKit

struct SplitsSummaryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    @ObservedObject var messageReceiptVM: MessageReceiptViewModel
    @ObservedObject var tabContextVM: TabContextViewModel
    let bus: MessageBus
    @State private var split: SplitPayload
    /// Receipt items with partition wire fields. Mutable so the Tap-to-Claim
    /// recipient flow can update per-item rs/sh/cu in place, then persist
    /// both `split` and `items` in one round trip via
    /// `messageReceiptVM.persist(split:items:...)`.
    @State private var items: [ReceiptItemPayload]
    let onEditSplit: (() -> Void)?
    let onEditReceipt: (() -> Void)?
    let onRemoveFromTab: (() -> Void)?
    let onClose: (() -> Void)?
    let onRequestCollapse: (() -> Void)?

    private var canEdit: Bool {
        guard let payload = messageReceiptVM.openedMessagePayload else { return false }
        let myUid = KeychainHelper.getOrCreateUserId()
        return payload.canEdit(myUid: myUid, userTabs: tabContextVM.userTabs)
    }

    private var isTabReceipt: Bool { messageReceiptVM.openedMessagePayload?.tid != nil }

    @State private var selectedIndex: Int? = nil
    /// True when the recipient has made claim changes that haven't been
    /// committed yet. Enables the Save button and gates the Firestore-
    /// listener overwrite so other recipients' updates don't clobber local
    /// pending claims mid-edit.
    @State private var hasUnsavedClaims: Bool = false

    private enum MyBillState { case choosing, joined, notInBill }
    @State private var billState: MyBillState = .choosing

    private enum TabMembershipState { case loading, member, notMember }
    @State private var tabMembershipState: TabMembershipState = .loading

    /// Cache of uid → display name fetched from Firestore.
    @State private var uidDisplayNames: [String: String] = [:]

    /// Payer's payment methods fetched from Firestore.
    @State private var payerPaymentMethods: [PaymentMethod]? = nil

    private struct PaySheetInfo: Identifiable {
        let id = UUID()
        let toName: String    // payer (being paid)
        let fromName: String  // me (paying)
        let amountCents: Int
        let guestIndex: Int
        let methods: [PaymentMethod]
    }
    @State private var paySheetInfo: PaySheetInfo? = nil
    @State private var selectedSection: DetailSection = .splits
    @State private var showCapture: Bool = false
    @State private var headerScrollOffset: CGFloat = 0
    @State private var initializedClaimStateBillId: String? = nil

    @Environment(\.openURL) private var openURL

    private enum DetailSection {
        case splits
        case receipt
    }

    private let expandedHeaderHeight: CGFloat = 130
    private let collapsedHeaderHeight: CGFloat = 76
    private let headerCollapseRange: CGFloat = 60

    init(
        coordinator: AppCoordinator,
        receiptDraftVM: ReceiptDraftViewModel,
        messageReceiptVM: MessageReceiptViewModel,
        tabContextVM: TabContextViewModel,
        bus: MessageBus,
        split: SplitPayload,
        items: [ReceiptItemPayload],
        onEditSplit: (() -> Void)? = nil,
        onEditReceipt: (() -> Void)? = nil,
        onRemoveFromTab: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onRequestCollapse: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.receiptDraftVM = receiptDraftVM
        self.messageReceiptVM = messageReceiptVM
        self.tabContextVM = tabContextVM
        self.bus = bus
        self._split = State(initialValue: split)
        self._items = State(initialValue: items)
        self.onEditSplit = onEditSplit
        self.onEditReceipt = onEditReceipt
        self.onRemoveFromTab = onRemoveFromTab
        self.onClose = onClose
        self.onRequestCollapse = onRequestCollapse
    }

    private var receipt: ReceiptDisplay? {
        receiptDraftVM.currentReceipt
    }

    private var captureImage: UIImage? {
        receiptDraftVM.scanImageCropped ?? receiptDraftVM.scanImageOriginal
    }

    private var currentBillId: String? {
        messageReceiptVM.openedMessageDocId ?? messageReceiptVM.openedMessagePayload?.r.id
    }

    private var hasIgnoredListForBill: Bool {
        messageReceiptVM.hasIgnoredUUIDsList(for: currentBillId)
    }

    private var hasClaimableSlots: Bool {
        // Tap-to-Claim bills start with everyone at $0 owed, so the regular
        // `includedIndices` filter (which requires owed > 0) finds nothing.
        // Treat any slot without a uid as claimable in that mode — recipients
        // pick up an owed balance only after they claim an item.
        if split.cl == true {
            return split.g.contains { $0.uid == nil }
        }
        return includedIndices.contains { split.g.indices.contains($0) && split.g[$0].uid == nil }
    }

    private func addCurrentUserToIgnored() {
        let myUid = KeychainHelper.getOrCreateUserId()
        messageReceiptVM.addIgnoredUUID(myUid, for: currentBillId)
    }

    private func removeCurrentUserFromIgnoredIfPresent() {
        let myUid = KeychainHelper.getOrCreateUserId()
        messageReceiptVM.removeIgnoredUUID(myUid, for: currentBillId)
    }

    private func isCurrentUserIgnored() -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        return messageReceiptVM.isIgnoredUUID(myUid, for: currentBillId)
    }

    private func unclaimCurrentUserIfNeeded() -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        guard let gi = split.g.firstIndex(where: { $0.uid == myUid }) else { return false }
        // Leaving a bill clears BOTH uid and the stored slot name. The
        // display layer falls through to "Guest \(gi + 1)" automatically
        // (see displayName(for:) above) so the slot reads as a clean
        // unclaimed slot for whoever views the bill next. This is
        // distinct from leaving a TAB (which preserves slot identity in
        // historical bills); only opt-out-of-this-bill resets the slot.
        split.g[gi].uid = nil
        split.g[gi].n = ""
        return true
    }

    private var headerTitle: String {
        receipt?.title ?? messageReceiptVM.openedMessagePayload?.r.t ?? "Receipt"
    }

    private var headerDateText: String {
        receipt?.dateText ?? "—"
    }

    private var associatedTab: LootTab? {
        if let receiptTab = tabContextVM.receiptTab {
            return receiptTab
        }
        if let payloadTab = messageReceiptVM.openedMessagePayload?.tab {
            return LootTab.minimal(id: payloadTab.id, name: payloadTab.n, colorHex: payloadTab.c)
        }
        if isTabReceipt {
            return tabContextVM.activeTab
        }
        return nil
    }

    private var headerBackgroundColor: Color {
        if isTabReceipt, let colorHex = associatedTab?.colorHex {
            return Color(hex: colorHex)
        }
        return Color(.systemBackground)
    }

    private var headerPrimaryStyle: Color {
        isTabReceipt ? .white : .primary
    }

    private var headerSecondaryStyle: Color {
        isTabReceipt ? .white.opacity(0.8) : .secondary
    }

    private func openAssociatedTab() {
        if let target = associatedTab {
            // Prefer the live activeTab when it points at the same tab id —
            // the Firestore listener keeps it populated with full members and
            // balances, whereas `associatedTab` may have fallen back to a
            // payload-derived `LootTab.minimal` stub (empty members) that
            // would briefly render "no members + UUID-as-name" until the
            // listener races back. The property-level guard in LootUIModel
            // also catches this, but skipping the write here is cleaner.
            if let active = tabContextVM.activeTab, active.id == target.id {
                // Same tab — no-op, preserve the live state.
            } else {
                tabContextVM.activeTab = target
            }
        }
        onClose?()
    }

    private var headerNavButtonTitle: String {
        if isTabReceipt && tabMembershipState == .member {
            return "View Tab"
        }
        return "Back"
    }

    private var headerNavButtonIcon: String {
        if isTabReceipt && tabMembershipState == .member {
            return "rectangle.stack.fill"
        }
        return "arrow.left"
    }

    private func handleHeaderNavButtonTap() {
        if isTabReceipt && tabMembershipState == .member {
            openAssociatedTab()
        } else {
            onRequestCollapse?()
            onClose?()
        }
    }

    private var headerCollapseProgress: CGFloat {
        min(max(headerScrollOffset / headerCollapseRange, 0), 1)
    }

    private var currentHeaderHeight: CGFloat {
        expandedHeaderHeight - ((expandedHeaderHeight - collapsedHeaderHeight) * headerCollapseProgress)
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat, progress: CGFloat) -> CGFloat {
        from + ((to - from) * progress)
    }

    @ViewBuilder
    private var headerDateLabel: some View {
        Text(headerDateText)
            .font(.system(size: 15))
            .foregroundStyle(headerSecondaryStyle)
            .opacity(max(0, 1 - Double(headerCollapseProgress * 1.8)))
            .offset(y: -headerCollapseProgress * 8)
    }

    @ViewBuilder
    private var headerTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.system(size: lerp(28, 21, progress: headerCollapseProgress), weight: .bold))
                .foregroundStyle(headerPrimaryStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            headerDateLabel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var headerNavLabelWidth: CGFloat {
        lerp(72, 0, progress: headerCollapseProgress)
    }

    private var headerNavMinWidth: CGFloat {
        lerp(108, 44, progress: headerCollapseProgress)
    }

    private var headerNavTitleOpacity: Double {
        max(0, 1 - Double(headerCollapseProgress * 2.2))
    }

    @ViewBuilder
    private var headerNavButton: some View {
        Button {
            handleHeaderNavButtonTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: headerNavButtonIcon)
                    .font(.system(size: 15, weight: .semibold))

                Text(headerNavButtonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .opacity(headerNavTitleOpacity)
                    .frame(width: headerNavLabelWidth, alignment: .leading)
                    .clipped()
            }
            .foregroundStyle(isTabReceipt ? headerBackgroundColor : .blue)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(minWidth: headerNavMinWidth)
            .background(isTabReceipt ? Color.white : Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var headerSectionToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedSection = selectedSection == .splits ? .receipt : .splits
            }
        } label: {
            Image(systemName: selectedSection == .splits ? "doc.text" : "chart.pie.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isTabReceipt ? headerBackgroundColor : .blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isTabReceipt ? Color.white : Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 8) {
            headerNavButton
            headerSectionToggleButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func presentPendingRequestIfPossible() {
        guard paySheetInfo == nil,
              let pending = messageReceiptVM.pendingPayRequest,
              let docId = messageReceiptVM.openedMessageDocId,
              pending.receiptDocId == docId,
              let debtorId = pending.debtorId,
              let creditorId = pending.creditorId,
              let debtorIndex = split.g.firstIndex(where: { $0.uid == debtorId }),
              split.g.indices.contains(split.pi),
              split.g[split.pi].uid == creditorId,
              let methods = payerPaymentMethods, !methods.isEmpty
        else { return }

        paySheetInfo = PaySheetInfo(
            toName: displayName(for: split.pi),
            fromName: displayName(for: debtorIndex),
            amountCents: pending.amountCents,
            guestIndex: debtorIndex,
            methods: methods
        )
        messageReceiptVM.pendingPayRequest = nil
    }

    private var includedIndices: [Int] {
        split.g.indices.filter { split.o.indices.contains($0) && split.o[$0] > 0 }
    }

    private var safeTotal: Int {
        max(0, split.tot)
    }

    private func displayName(for idx: Int) -> String {
        let g = split.g[idx]
        let myUid = KeychainHelper.getOrCreateUserId()

        // 1. If this slot has a uid, show that user's display name
        if let uid = g.uid, !uid.isEmpty {
            if uid == myUid {
                let myName = myDisplayNameFromDefaults()
                return myName.isEmpty ? "Me" : myName
            }
            if let cached = uidDisplayNames[uid], !cached.isEmpty {
                return cached
            }
        }

        // 2. If the bill creator manually entered a name, show it
        let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }

        // 3. Fallback
        return "Guest \(idx + 1)"
    }

    private func owed(for idx: Int) -> Int {
        guard split.o.indices.contains(idx) else { return 0 }
        return max(0, split.o[idx])
    }

    /// Fetches Firestore displayNames for any uid in the current split that
    /// hasn't been resolved yet. Idempotent — runs once on .task and again
    /// whenever the payload changes (e.g. a Firestore refresh adds a
    /// joiner's uid that wasn't in the original inline payload).
    @MainActor
    private func fetchMissingDisplayNames() async {
        let myUid = KeychainHelper.getOrCreateUserId()
        let candidates = Set(split.g.compactMap(\.uid))
            .filter { $0 != myUid && !$0.isEmpty && uidDisplayNames[$0] == nil }
        for uid in candidates {
            do {
                if let name = try await TabService.shared.fetchUserDisplayName(userId: uid) {
                    uidDisplayNames[uid] = name
                }
            } catch {
                print("[SplitsSummaryView] Failed to fetch name for \(uid): \(error)")
            }
        }
    }

    // MARK: - Paid status

    private func isPaid(guestIndex: Int) -> Bool {
        guard let pd = split.pd, pd.indices.contains(guestIndex) else { return false }
        return pd[guestIndex]
    }

    private func togglePaid(guestIndex: Int) {
        // Ensure array exists and is the right size
        if split.pd == nil {
            split.pd = Array(repeating: false, count: split.g.count)
        }
        while split.pd!.count < split.g.count {
            split.pd!.append(false)
        }
        split.pd![guestIndex].toggle()
        persistSplit(action: .paidToggled(paid: split.pd![guestIndex]))
    }

    /// Returns true if the current user can toggle paid for this guest's transaction.
    private func canTogglePaid(guestIndex: Int) -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        // Payer can toggle any transaction
        if split.g[split.pi].uid == myUid { return true }
        // The guest themselves can toggle their own transaction
        if split.g[guestIndex].uid == myUid { return true }
        return false
    }

    private func percentText(_ cents: Int) -> String {
        guard safeTotal > 0 else { return "0%" }
        let p = (Double(cents) / Double(safeTotal)) * 100
        return String(format: "%.0f%%", p)
    }

    // Use shared BadgeColors
    private func colorForSlot(_ i: Int) -> Color {
        BadgeColors.color(for: i)
    }

    // Get items assigned to a specific guest slot (for byItems mode)
    private func itemsForSlot(_ slotIndex: Int) -> [ReceiptItemPayload] {
        items.filter { $0.rs.contains(slotIndex) }
    }

    private func sumBeforeIncludedSlot(_ includedSlot: Int) -> Int {
        guard includedSlot > 0 else { return 0 }
        let prev = includedIndices.prefix(includedSlot)
        return prev.reduce(0) { $0 + owed(for: $1) }
    }

    private func sumThroughIncludedSlot(_ includedSlot: Int) -> Int {
        let upTo = includedIndices.prefix(includedSlot + 1)
        return upTo.reduce(0) { $0 + owed(for: $1) }
    }

    private func lastActiveIndex(idx: Int) -> Int {
        for j in stride(from: idx - 1, through: 0, by: -1) {
            if includedIndices[j] > 0 {
                return j
            }
        }
        return 0
    }

    /// The included-array index for the current user, if claimed.
    private var myIncludedIndex: Int? {
        let myUid = KeychainHelper.getOrCreateUserId()
        return includedIndices.firstIndex(where: { split.g[$0].uid == myUid })
    }

    // MARK: - Transaction row

    @ViewBuilder
    private func transactionRow(from: String, to: String, amount: Int, color: Color, guestIndex: Int, showPayButton: Bool = false, showRequestButton: Bool = false) -> some View {
        let paid = isPaid(guestIndex: guestIndex)
        let editable = canTogglePaid(guestIndex: guestIndex)
        let canPay = showPayButton && !paid && !(payerPaymentMethods?.isEmpty ?? true)
        let canRequest = showRequestButton && !paid

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(from)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(paid ? .secondary : .primary)
                    .strikethrough(paid)
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(paid ? color.opacity(0.4) : color)

                Text(to)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(paid ? .secondary : .primary)
                    .strikethrough(paid)
                    .lineLimit(1)

                Spacer()

                Text(ReceiptDisplay.money(amount))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(paid ? .secondary : .primary)
                    .strikethrough(paid)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        togglePaid(guestIndex: guestIndex)
                    }
                } label: {
                    Image(systemName: paid ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(paid ? .green : Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
                .disabled(!editable)
                .opacity(editable ? 1 : 0.4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(paid ? Color.green.opacity(0.06) : color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if canPay {
                Button {
                    if let methods = payerPaymentMethods {
                        paySheetInfo = PaySheetInfo(
                            toName: to,
                            fromName: from,
                            amountCents: amount,
                            guestIndex: guestIndex,
                            methods: methods
                        )
                    }
                } label: {
                    Label("Pay Now", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else if canRequest {
                Button {
                    bus.sendRequestCard(
                        creditorName: to,
                        debtorName: from,
                        amountCents: amount,
                        tabColorHex: nil,
                        metadata: RequestCardMetadata(
                            receiptDocId: messageReceiptVM.openedMessageDocId,
                            tabId: nil,
                            creditorId: split.g[split.pi].uid,
                            debtorId: split.g[guestIndex].uid
                        )
                    )
                } label: {
                    Label("Request", systemImage: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Guest row (reusable)

    @ViewBuilder
    private func guestRow(includedIdx i: Int, guestIdx gi: Int, showTransactions: Bool, included: [Int]) -> some View {
        let guestItems = itemsForSlot(gi)
        let count = included.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ColoredCircleBadge(
                    text: BadgeColors.initials(from: displayName(for: gi), fallback: gi),
                    color: colorForSlot(gi)
                )

                Text(displayName(for: gi))
                    .font(.system(size: 15, weight: i == selectedIndex ? .semibold : .regular))

                if split.pi == i {
                    Text("Payer")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(ReceiptDisplay.money(owed(for: gi)))
                    .font(.system(size: 15, weight: .semibold))
            }

            // Show items for this guest
            if !guestItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(guestItems, id: \.id) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForSlot(gi).opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(item.l)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 8)
            }

            // Transactions
            if showTransactions {
                VStack(spacing: 6) {
                    Rectangle()
                        .fill(Color(.separator).opacity(0.4))
                        .frame(height: 1)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    if split.pi == gi {
                        // Payer: show who owes them
                        let myUid = KeychainHelper.getOrCreateUserId()
                        let iAmPayer = split.g[gi].uid == myUid
                        ForEach(0..<count, id: \.self) { j in
                            let gj = included[j]
                            if gj != gi {
                                transactionRow(
                                    from: displayName(for: gj),
                                    to: displayName(for: gi),
                                    amount: owed(for: gj),
                                    color: colorForSlot(gj),
                                    guestIndex: gj,
                                    showRequestButton: !isTabReceipt && iAmPayer && !(split.g[gj].uid ?? "").isEmpty
                                )
                            }
                        }
                    } else {
                        // Non-payer: show what they owe the payer
                        transactionRow(
                            from: displayName(for: gi),
                            to: displayName(for: split.pi),
                            amount: owed(for: gi),
                            color: colorForSlot(split.pi),
                            guestIndex: gi,
                            showPayButton: !isTabReceipt
                        )
                    }
                }
            }
        }
    }

    // MARK: - Slot claim / unclaim

    private func claimSlot(at guestIndex: Int, broadcast: Bool = true) {
        let myUid = KeychainHelper.getOrCreateUserId()
        split.g[guestIndex].uid = myUid

        // Per spec: g[i].n is the SENDER-set stored name and is never
        // overwritten by joiners. Display falls through to g.n only when
        // uid is unset; with uid set, the recipient's view looks up the
        // user's display name via the Firestore users/{uid} doc.
        // To shrink the lookup race for cross-sender viewers, ensure our
        // user doc carries our current display name before the broadcast
        // has propagated.
        let myName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
        if !myName.isEmpty {
            Task { try? await TabService.shared.createOrUpdateUser(userId: myUid, displayName: myName) }
        }

        removeCurrentUserFromIgnoredIfPresent()
        billState = .joined
        persistSplit(broadcast: broadcast, action: .claimed)

        // Select the newly claimed slot on the donut
        if let idx = myIncludedIndex {
            selectedIndex = idx
        }
    }

    /// Auto-claim a slot on first view of the bill. Skips the chat bubble
    /// broadcast: iOS won't auto-send an MSConversation.send call this far
    /// from a user tap (the message lands in the input field draft instead).
    /// The next *manual* interaction will broadcast the latest state with a
    /// real user-tap context, which iOS will auto-send normally.
    private func autoClaimSlotAfterViewLoad(at guestIndex: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard split.g.indices.contains(guestIndex), split.g[guestIndex].uid == nil else { return }
            claimSlot(at: guestIndex, broadcast: false)
        }
    }

    private func optOutOfBill() {
        _ = unclaimCurrentUserIfNeeded()
        addCurrentUserToIgnored()
        selectedIndex = nil
        billState = .notInBill
        persistSplit(action: .optedOut)
    }

    private func reconcileClaimState(shouldAutoJoin: Bool = false) {
        let myUid = KeychainHelper.getOrCreateUserId()
        let alreadyClaimed = split.g.contains { $0.uid == myUid }

        if hasIgnoredListForBill {
            if isCurrentUserIgnored() {
                if alreadyClaimed {
                    _ = unclaimCurrentUserIfNeeded()
                    persistSplit(action: .optedOut)
                }
                billState = .notInBill
                selectedIndex = nil
            } else if alreadyClaimed {
                billState = .joined
                if let myIdx = myIncludedIndex {
                    selectedIndex = myIdx
                }
            } else if hasClaimableSlots {
                attemptAutoJoinOrChoose(shouldAutoJoin: shouldAutoJoin)
            } else {
                billState = .notInBill
                selectedIndex = nil
            }
        } else {
            // Legacy behavior (messages without ignoredUUIDs list)
            if alreadyClaimed {
                billState = .joined
                if let myIdx = myIncludedIndex {
                    selectedIndex = myIdx
                }
            } else {
                attemptAutoJoinOrChoose(shouldAutoJoin: shouldAutoJoin)
            }
        }
    }

    /// On first view of a bill, auto-claim a slot for the current user when
    /// it's unambiguous (equal-split, or a single free slot). Otherwise leave
    /// the user in the choosing state. Skipped when reconciling from a live
    /// Firestore update so a remote change doesn't trigger an auto-claim.
    private func attemptAutoJoinOrChoose(shouldAutoJoin: Bool) {
        // Tap-to-Claim bills implicitly auto-bind the recipient to a free
        // slot on view load — they claim items directly, no opt-in/out
        // prompt. Skips the `shouldAutoJoin` gate (which exists for the
        // listener-fed reconcile path) since cl=true always wants auto-bind.
        if split.cl == true, let i = split.g.firstIndex(where: { $0.uid == nil }) {
            autoClaimSlotAfterViewLoad(at: i)
            return
        }

        guard shouldAutoJoin else {
            billState = .choosing
            return
        }
        if split.m == .equally, let i = split.g.firstIndex(where: { $0.uid == nil }) {
            autoClaimSlotAfterViewLoad(at: i)
        } else if split.m != .equally {
            let freeSlots = split.g.indices.filter { split.g[$0].uid == nil }
            if freeSlots.count == 1 {
                autoClaimSlotAfterViewLoad(at: freeSlots[0])
            } else {
                billState = .choosing
            }
        } else {
            billState = .choosing
        }
    }

    private func persistSplit(broadcast: Bool = true, action: BillUpdateAction = .edited) {
        messageReceiptVM.persist(split: split, broadcast: broadcast, action: action, via: bus)
    }

    @ViewBuilder
    private var sharedHeader: some View {
        ZStack {
            headerTitleBlock
            headerActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: currentHeaderHeight)
        .background(headerBackgroundColor)
    }

    private var scrollHeaderSpacer: some View {
        Color.clear
            .frame(height: currentHeaderHeight)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: SplitsSummaryScrollOffsetKey.self,
                            value: max(0, -geo.frame(in: .named("summaryScroll")).minY)
                        )
                }
            )
    }

    @ViewBuilder
    private var receiptDetailsSection: some View {
        if let receipt {
            VStack(alignment: .leading, spacing: 14) {
                if isClaimModeForMe {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 13))
                            .foregroundStyle(.blue)
                        Text("Tap dotted circles to claim your shares. Items claimed by someone else are locked — only the original splitter can change how they're divided.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                }
                VStack(spacing: 0) {
                        if receiptDraftVM.itemsLoadingState.isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.9)
                                Text("Loading items...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else if receipt.items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text("No items")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(receipt.items) { item in
                                itemRow(displayItem: item)
                                if item.id != receipt.items.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    TotalsBox(receipt: receipt)
                        .padding(.horizontal, 16)

                    if isClaimModeForMe {
                        Button {
                            commitClaimChanges()
                        } label: {
                            Label(
                                hasUnsavedClaims ? "Save Claims" : "All Claims Saved",
                                systemImage: hasUnsavedClaims ? "checkmark.circle.fill" : "checkmark.circle"
                            )
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(hasUnsavedClaims ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(hasUnsavedClaims ? Color.blue : Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasUnsavedClaims)
                        .padding(.horizontal, 16)
                    }

                    VStack(spacing: 10) {
                        if canEdit {
                            Button {
                                onEditReceipt?()
                            } label: {
                                Label("Edit Receipt", systemImage: "pencil")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        if captureImage != nil {
                            Button {
                                showCapture = true
                            } label: {
                                Label("View Receipt Capture", systemImage: "doc.viewfinder")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
        } else {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var splitDetailsSection: some View {
        let included = includedIndices
        let count = included.count
        let selectedGuestIndex: Int? = selectedIndex
            .map { max(0, min($0, max(0, count - 1))) }
            .flatMap { count > 0 ? included[$0] : nil }

        VStack(alignment: .leading, spacing: 16) {
            GeometryReader { geo in
                    let size = min(geo.size.width, 230)
                    let lineW: CGFloat = 30
                    let dimmer = Color(white: 0.55)
                    let seamNudgeDegrees = 1.0

                    ZStack {
                        Circle()
                            .stroke(Color(.secondarySystemBackground),
                                    style: .init(lineWidth: lineW, lineCap: .round))
                            .frame(width: size, height: size)

                        ForEach((0..<count).reversed(), id: \.self) { i in
                            if safeTotal > 0 {
                                let gi = included[i]
                                let start = Double(sumBeforeIncludedSlot(i)) / Double(safeTotal)
                                let end = Double(sumThroughIncludedSlot(i)) / Double(safeTotal)
                                if end > start {
                                    Circle()
                                        .trim(from: start, to: end)
                                        .stroke(colorForSlot(gi),
                                                style: .init(lineWidth: lineW, lineCap: .round))
                                        .colorMultiply(selectedIndex == nil || i == selectedIndex ? .white : dimmer)
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: size, height: size)
                                }
                            }
                        }

                        if count > 0, safeTotal > 0 {
                            let lastI = count - 1
                            let lastGi = included[lastI]
                            Circle()
                                .fill(colorForSlot(lastGi))
                                .frame(width: lineW, height: lineW)
                                .offset(
                                    x: cos(Angle.degrees(-90 - seamNudgeDegrees).radians) * (size / 2),
                                    y: sin(Angle.degrees(-90 - seamNudgeDegrees).radians) * (size / 2)
                                )
                                .colorMultiply(selectedIndex == nil || selectedIndex == lastI ? .white : dimmer)
                        }

                        if let selectedIndex, count > 0, safeTotal > 0, selectedIndex < count {
                            let gi = included[selectedIndex]
                            let start = Double(sumBeforeIncludedSlot(selectedIndex)) / Double(safeTotal)
                            let startAngle = Angle.degrees(start * 360 - 90 + seamNudgeDegrees)
                            let radius = size / 2
                            Circle()
                                .fill(colorForSlot(gi))
                                .frame(width: lineW, height: lineW)
                                .offset(
                                    x: cos(startAngle.radians) * radius,
                                    y: sin(startAngle.radians) * radius
                                )
                        }

                        VStack(spacing: 6) {
                            if let gi = selectedGuestIndex {
                                Text(displayName(for: gi))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(ReceiptDisplay.money(owed(for: gi)))
                                    .font(.system(size: 34, weight: .bold))
                                Text(percentText(owed(for: gi)))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Total")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(ReceiptDisplay.money(safeTotal))
                                    .font(.system(size: 34, weight: .bold))
                                Text("split \(count) ways")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let cx = geo.size.width / 2
                        let cy = geo.size.height / 2
                        let dx = value.location.x - cx
                        let dy = value.location.y - cy
                        let dist = sqrt(dx * dx + dy * dy)
                        let innerR = size / 2 - lineW / 2
                        let outerR = size / 2 + lineW / 2

                        guard dist >= innerR && dist <= outerR, safeTotal > 0 else {
                            selectedIndex = nil
                            return
                        }

                        var angle = atan2(dy, dx) / (2 * .pi) + 0.25
                        if angle < 0 { angle += 1 }
                        if angle >= 1 { angle -= 1 }

                        for i in 0..<count {
                            let start = Double(sumBeforeIncludedSlot(i)) / Double(safeTotal)
                            let end = Double(sumThroughIncludedSlot(i)) / Double(safeTotal)
                            if angle >= start && angle < end {
                                selectedIndex = i
                                return
                            }
                        }
                    })
            }
            .frame(height: 240)

            splitPeopleSection(included: included, count: count)

            if canEdit {
                HStack(spacing: 10) {
                    Button {
                        onEditSplit?()
                    } label: {
                        Text("Edit Splits")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    if isTabReceipt {
                        Button {
                            onRemoveFromTab?()
                        } label: {
                            Text("Remove From Tab")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }

            Spacer().frame(height: 60)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .contentShape(Rectangle())
        .onTapGesture { selectedIndex = nil }
    }

    @ViewBuilder
    private func splitPeopleSection(included: [Int], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch billState {
            case .joined:
                if let myIdx = myIncludedIndex {
                    let myGi = included[myIdx]

                    Button {
                        selectedIndex = myIdx
                    } label: {
                        guestRow(
                            includedIdx: myIdx,
                            guestIdx: myGi,
                            showTransactions: !isTabReceipt,
                            included: included
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isTabReceipt {
                        let myUid = KeychainHelper.getOrCreateUserId()
                        let iAmPayer = split.g[split.pi].uid == myUid
                        if !iAmPayer {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    optOutOfBill()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Leave this bill")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

            case .choosing:
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        Text("Which one are you?")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Tap a guest below to claim your spot")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            optOutOfBill()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text("I'm not in this bill")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            case .notInBill:
                VStack(spacing: 10) {
                    Text("You're not in this bill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            if hasClaimableSlots {
                                billState = .choosing
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("I'm in this bill")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(hasClaimableSlots ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background((hasClaimableSlots ? Color.blue.opacity(0.08) : Color(.tertiarySystemFill)))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasClaimableSlots)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.top, 15)

        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { i in
                    if billState != .joined || i != myIncludedIndex {
                        let gi = included[i]
                        let isUnclaimed = split.g[gi].uid == nil

                        Button {
                            if billState == .choosing && isUnclaimed {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    claimSlot(at: gi)
                                }
                            }
                            selectedIndex = i
                        } label: {
                            guestRow(
                                includedIdx: i,
                                guestIdx: gi,
                                showTransactions: false,
                                included: included
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(i == selectedIndex ? Color(.secondarySystemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                billState == .choosing && isUnclaimed
                                    ? RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                        .foregroundStyle(Color.blue.opacity(0.5))
                                    : nil
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    var body: some View {
        Group {
            if isTabReceipt && tabMembershipState == .notMember {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        Text("You are not a part of this tab.")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Request an invite to join.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if isTabReceipt && tabMembershipState == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .top) {
                    ScrollView {
                        VStack(spacing: 0) {
                            scrollHeaderSpacer

                            if isTabReceipt {
                                Color.clear.frame(height: 16)
                            }

                            if selectedSection == .splits {
                                splitDetailsSection
                            } else {
                                receiptDetailsSection
                            }
                        }
                    }
                    .coordinateSpace(name: "summaryScroll")

                    sharedHeader
                }
                .onPreferenceChange(SplitsSummaryScrollOffsetKey.self) { headerScrollOffset = $0 }
            }
        }
        .onAppear {
            let initBillId = currentBillId ?? "__legacy__"
            guard initializedClaimStateBillId != initBillId else { return }
            initializedClaimStateBillId = initBillId
            reconcileClaimState(shouldAutoJoin: true)
            // Tap-to-Claim recipients land on the receipt items section so
            // they can start claiming immediately. The donut/per-person area
            // doesn't tell them much before they've claimed anything.
            if isClaimModeForMe {
                selectedSection = .receipt
            }
        }
        .onChange(of: messageReceiptVM.openedMessagePayload?.s) { _, latestSplit in
            guard let latestSplit, latestSplit != split else { return }
            split = latestSplit
            reconcileClaimState()
        }
        .onChange(of: messageReceiptVM.openedMessagePayload?.r.i) { _, latestItems in
            // Real-time sync for the Tap-to-Claim recipient flow: when another
            // viewer claims an item via the Firestore listener, refresh the
            // local @State `items` so the partition widget rerenders. Equality
            // guard avoids re-firing on our own writes (the listener bounces
            // them back through openedMessagePayload). Pending-claims guard
            // prevents a remote update from clobbering the user's uncommitted
            // local edits — they'd lose what they've tapped between Save events.
            guard let latestItems, latestItems != items else { return }
            guard !hasUnsavedClaims else { return }
            items = latestItems
        }
        .task {
            let myUid = KeychainHelper.getOrCreateUserId()

            // Check tab membership — non-members see a locked view
            if isTabReceipt, let tabId = messageReceiptVM.openedMessagePayload?.tid {
                if tabContextVM.userTabs.contains(where: { $0.id == tabId }) {
                    tabMembershipState = .member
                } else {
                    let tab = try? await TabService.shared.fetchTab(id: tabId)
                    tabMembershipState = tab?.memberIds.contains(myUid) == true ? .member : .notMember
                }
            } else {
                tabMembershipState = .member
            }

            await fetchMissingDisplayNames()

            // Fetch payer's payment methods (only if I'm not the payer, and not a tab receipt)
            if !isTabReceipt, let payerUid = split.g[split.pi].uid, payerUid != myUid {
                payerPaymentMethods = try? await TabService.shared.fetchPaymentMethods(userId: payerUid)
            }

        }
        .onChange(of: messageReceiptVM.openedMessagePayload?.s) { _, newSplit in
            if let newSplit {
                split = newSplit
                // The fresh payload may have introduced new uids
                // (e.g. a joiner who auto-claimed a slot after we first
                // appeared). Trigger a non-blocking fetch so their
                // displayName populates uidDisplayNames and badges stop
                // showing "Guest N".
                Task { await fetchMissingDisplayNames() }
            }
        }
        .onChange(of: payerPaymentMethods) { _, _ in
            presentPendingRequestIfPossible()
        }
        .sheet(item: $paySheetInfo) { info in
            let note = messageReceiptVM.openedMessagePayload?.r.t ?? "Loot"
            TabPayNowSheet(
                toName: info.toName,
                amountCents: info.amountCents,
                methods: info.methods,
                tabColorHex: nil,
                onSelectMethod: { method in
                    // ORDERING RULE: togglePaid (which broadcasts the bill
                    // update via persistSplit → bus.sendBillUpdate) MUST fire
                    // FIRST, before any other conversation.send or extension
                    // dismissal. The broadcast retracts+replaces the original
                    // bubble with the paid-marked card, and only auto-sends
                    // when isConversationAutoSendReady is true at the moment
                    // iOS processes the call. Subsequent operations
                    // (sendSettlementCard's conversation.send, sendApplePayHandoff,
                    // openInSafari) all degrade auto-send eligibility — even
                    // when called synchronously in the same tap closure, iOS
                    // appears to invalidate the user-tap context after the
                    // first conversation.send, so a bill update fired second
                    // gets demoted from `conversation.send` to "insert into
                    // draft" and the user has to manually send (which then
                    // appends a new bubble instead of retracting).
                    //
                    // SETTLEMENT CARD POLICY: only sent for tab-attached
                    // receipts. For a non-tabbed receipt, the bill-update
                    // broadcast above already retracts+replaces the bubble
                    // with paid styling — that IS the "sent" signal. A
                    // separate "sent a payment" card would be redundant
                    // chat clutter. For tab-attached receipts the
                    // settlement card represents the user's payment
                    // against the tab balance and is kept.
                    //
                    // Apple Pay: stage the compact-mode reminder, broadcast
                    // the bill update, optionally send the handoff card
                    // (tab receipts only), navigate back to tabview (the
                    // receipt viewer would otherwise hide the compact
                    // reminder behind it), then collapse the extension.
                    if method.type == .applePay {
                        let tabColor = associatedTab?.colorHex
                        messageReceiptVM.pendingApplePayInfo = PendingApplePayInfo(
                            toName: info.toName,
                            amountCents: info.amountCents,
                            tabColorHex: tabColor
                        )
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            togglePaid(guestIndex: info.guestIndex)
                        }
                        if isTabReceipt {
                            bus.sendApplePayHandoff(fromName: info.fromName, toName: info.toName,
                                                    amountCents: info.amountCents, tabColorHex: tabColor)
                        }
                        // Preserve the tab association so LootTabView can color
                        // its compact strip with the same tab as the receipt.
                        // Skip the write if activeTab already points at this
                        // tab — `associatedTab` may be a payload-derived
                        // minimal stub that would downgrade rich live state.
                        if let target = associatedTab,
                           tabContextVM.activeTab?.id != target.id {
                            tabContextVM.activeTab = target
                        }
                        onClose?()
                        onRequestCollapse?()
                        return
                    }

                    let effectiveBankURL: String?
                    if method.type == .zelle {
                        effectiveBankURL = savedPaymentMethods()
                            .first(where: { $0.type == .zelle })?.bankURL ?? method.bankURL
                    } else {
                        effectiveBankURL = method.bankURL
                    }
                    let deepLink = method.type.deepLinkURL(
                        identifier: method.identifier,
                        amountCents: info.amountCents,
                        note: note,
                        bankURL: effectiveBankURL,
                        payeeName: info.toName,
                        zelleData: method.zelleData
                    )
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        togglePaid(guestIndex: info.guestIndex)
                    }
                    if isTabReceipt {
                        bus.sendSettlementCard(fromName: info.fromName, toName: info.toName,
                                               amountCents: info.amountCents,
                                               methodName: method.type.displayName,
                                               tabColorHex: nil)
                    }
                    if let url = deepLink {
                        bus.openInSafari(url)
                    } else if method.type == .zelle {
                        UIPasteboard.general.string = method.identifier
                    }
                }
            )
        }
        .sheet(isPresented: $showCapture) {
            CapturePreviewView(image: captureImage) {
                showCapture = false
            }
        }
        .onAppear {
            presentPendingRequestIfPossible()
        }
        // Picker dialog removed — the inline `+` button grows the split
        // iteratively.
    }

    // MARK: - Item row (tap-to-claim aware)

    @ViewBuilder
    private func itemRow(displayItem item: ReceiptDisplay.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Left side is a Button only when this user can claim inline. The
            // sender (or anyone read-only) gets a plain HStack — no row-tap
            // claim path for them; they edit via the Edit Splits sheet.
            if isClaimModeForMe {
                Button {
                    handleItemRowTap(itemId: item.id)
                } label: {
                    HStack {
                        itemLabelBlock(item: item)
                        Spacer(minLength: 8)
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    itemLabelBlock(item: item)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 14)
                .padding(.vertical, 12)
            }

            claimOrAssigneeWidget(for: item)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func itemLabelBlock(item: ReceiptDisplay.Item) -> some View {
        let locked = isItemLockedForLocalUser(itemId: item.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(item.label)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(locked ? .secondary : .primary)
            }
            HStack(spacing: 4) {
                Text(ReceiptDisplay.money(item.priceCents))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                if let annotation = splitAnnotation(for: item.id) {
                    Text(annotation)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(locked ? 0.75 : 1.0)
    }

    /// "(split N ways)" annotation shown next to an item's price when the
    /// item's partition is multi-way (denominator > 1). Communicates the
    /// item's structure at a glance — replaces the older "1/N" label
    /// prefix, which conflated structure with the local user's share.
    private func splitAnnotation(for itemId: String) -> String? {
        guard let wireItem = items.first(where: { $0.id == itemId }) else { return nil }
        let partition = wireItem.itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let (denom, _) = SplitEditorViewModel.normalizedPartition(partition)
        guard denom > 1 else { return nil }
        return "(split \(denom) ways)"
    }

    /// True when the local user can't meaningfully interact with this item:
    /// someone else has claimed at least one share, the local user has
    /// none, AND there are no empty slots left to fill. Drives the lock
    /// icon + dimmed label in `itemLabelBlock`.
    private func isItemLockedForLocalUser(itemId: String) -> Bool {
        guard isClaimModeForMe else { return false }
        guard let wireItem = items.first(where: { $0.id == itemId }) else { return false }
        let partition = wireItem.itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let (_, slots) = SplitEditorViewModel.normalizedPartition(partition)
        let claimedPIDs = Set(slots.compactMap { $0 })
        guard !claimedPIDs.isEmpty else { return false }
        if claimedPIDs.contains(myCanonicalPID) { return false }
        return !slots.contains(nil)
    }

    /// Picks between the existing read-only assignee badges and the
    /// partition-aware claim widget. The widget renders for any Tap-to-Claim
    /// bill so the sender's read-only view still shows the partition state
    /// (filled + hollow slots), but interactivity is gated on
    /// `isClaimModeForMe` (sender viewing their own bill → read-only).
    @ViewBuilder
    private func claimOrAssigneeWidget(for item: ReceiptDisplay.Item) -> some View {
        if isClaimModeBill, let wireItem = items.first(where: { $0.id == item.id }) {
            claimWidget(displayItem: item, wireItem: wireItem)
        } else {
            HStack(spacing: 6) {
                // Resolve slot index from canonical assigneeIDs, then use the
                // local displayName helper so the badge text reflects the
                // Firestore-cached name for joined members and `myDisplayName`
                // for the local user.
                let assigneeSlots: [Int] = item.assigneeIDs.compactMap { pid in
                    split.g.slotIndex(for: pid)
                }
                ForEach(Array(assigneeSlots.enumerated()), id: \.offset) { _, slot in
                    ColoredCircleBadge(
                        text: BadgeColors.initials(from: displayName(for: slot), fallback: slot),
                        color: BadgeColors.color(for: slot)
                    )
                }
            }
        }
    }

    // MARK: - Tap-to-Claim widget (recipient side)

    /// True when this bill was sent in Tap-to-Claim mode. Drives the
    /// partition-aware display (circles + claimer badges) regardless of
    /// whether the local user can interact with it.
    private var isClaimModeBill: Bool {
        split.cl == true
    }

    /// True when the local user can claim/unclaim items inline. The sender of
    /// the bill is excluded — they edit through the Edit Splits sheet, not
    /// inline. Any other chat participant can claim in a `cl=true` bill (the
    /// first tap binds them to a free slot via `ensureMySlotBound`).
    private var isClaimModeForMe: Bool {
        guard isClaimModeBill else { return false }
        let myUid = KeychainHelper.getOrCreateUserId()
        if let payload = messageReceiptVM.openedMessagePayload, payload.su == myUid {
            return false
        }
        return true
    }

    /// Wire-canonical PersonID list, one per slot — uid for identified
    /// guests, `"slot-N"` for anonymous ones. Used to translate between
    /// item partitions (PersonID-keyed) and the wire format.
    private var canonicalSlotPIDs: [PersonID] {
        split.g.indices.map { split.g.personID(forSlot: $0) }
    }

    /// PersonID for the current user, derived from their Keychain uid.
    private var myCanonicalPID: PersonID {
        PersonID(rawValue: KeychainHelper.getOrCreateUserId())
    }

    @ViewBuilder
    private func claimWidget(displayItem: ReceiptDisplay.Item, wireItem: ReceiptItemPayload) -> some View {
        let partition = wireItem.itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let (denom, slots) = SplitEditorViewModel.normalizedPartition(partition)

        let myPID = myCanonicalPID

        HStack(spacing: 4) {
            // Leading `+` to grow the split. The structure of an item is
            // owned by whoever has already claimed a share — outsiders can
            // fill open slots but can't change the denominator. So show `+`
            // only when nobody has claimed yet (the item is still up for
            // grabs) OR the local user is already one of the claimers.
            if isClaimModeForMe
                && denom < split.g.count
                && localUserCanChangeStructure(slots: slots) {
                Button {
                    increaseClaimDenominator(itemId: wireItem.id)
                } label: {
                    dottedPlusBadge()
                }
                .buttonStyle(.plain)
            }

            ForEach(0..<denom, id: \.self) { i in
                let claimer = slots.indices.contains(i) ? slots[i] : nil
                if isClaimModeForMe {
                    // Tappable when: the slot is empty (anyone can claim it)
                    // OR the slot belongs to the local user (they can
                    // unclaim themselves). Other people's filled slots are
                    // static — only the owner can undo their own claim.
                    let isInteractive = (claimer == nil) || (claimer == myPID)
                    if isInteractive {
                        Button {
                            handleCircleTap(itemId: wireItem.id, shareIndex: i)
                        } label: {
                            if let pid = claimer {
                                claimerBadge(for: pid)
                            } else {
                                dottedClaimSlotBadge()
                            }
                        }
                        .buttonStyle(.plain)
                    } else if let pid = claimer {
                        claimerBadge(for: pid)
                    }
                } else {
                    if let pid = claimer {
                        claimerBadge(for: pid)
                    } else {
                        staticHollowCircle()
                    }
                }
            }
        }
    }

    /// Returns true when the local user is allowed to grow the item's
    /// structure (press `+`). Only the structure owner — the person who
    /// first established the split — can change the denominator. Outsiders
    /// (and even later joiners filling empty slots) can't widen or shrink
    /// the pie behind the original splitter's back.
    ///
    /// Structure owner is computed as the earliest-indexed non-nil slot's
    /// claimer. `+` appends to the end and auto-claim fills the lowest nil
    /// slot, so the original splitter stays in slot 0 unless they
    /// explicitly unclaim. If they do unclaim, ownership naturally
    /// transfers to whoever's left in the earliest filled slot.
    private func localUserCanChangeStructure(slots: [PersonID?]) -> Bool {
        let firstClaimer = slots.compactMap { $0 }.first
        guard let owner = firstClaimer else { return true }
        return owner == myCanonicalPID
    }

    /// Grows the claim widget's denominator by one. Recipient-side analogue
    /// of `SplitEditorViewModel.increaseDenominator`. Capped at `split.g.count`
    /// so the `+` can never exceed the chat's guest list.
    ///
    /// Auto-joins the local user: pressing `+` is the act of splitting, and
    /// the splitter is implicitly part of their own split. If the user
    /// already has a share, the new slot is left open for someone else.
    private func increaseClaimDenominator(itemId: String) {
        guard ensureMySlotBound(),
              let wireIdx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let partition = items[wireIdx].itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let (currentDenom, currentSlots) = SplitEditorViewModel.normalizedPartition(partition)
        guard currentDenom < split.g.count else { return }

        let myPID = myCanonicalPID
        var newSlots = currentSlots
        if !newSlots.contains(myPID), let nilIdx = newSlots.firstIndex(where: { $0 == nil }) {
            // Take the lowest empty slot so the splitter lands in slot 0 of
            // a fresh structure — keeps structure-owner stable as `+` grows.
            newSlots[nilIdx] = myPID
            newSlots.append(nil)
        } else {
            newSlots.append(nil)
        }

        let newPartition = ItemPartition.shares(
            denominator: currentDenom + 1,
            slots: newSlots
        )
        applyPartitionUpdate(itemIndex: wireIdx, newPartition: newPartition)
    }

    @ViewBuilder
    private func dottedPlusBadge() -> some View {
        Circle()
            .fill(Color.blue.opacity(0.08))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(Color.blue.opacity(0.65), lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.85))
            )
            .contentShape(Circle())
    }

    @ViewBuilder
    private func dottedClaimSlotBadge() -> some View {
        Circle()
            .fill(Color.gray.opacity(0.06))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                    )
            )
            .contentShape(Circle())
    }

    /// Non-interactive hollow circle used in the sender's read-only view of a
    /// Tap-to-Claim bill — no `+` icon, no pulse animation, no Button wrapper.
    /// Purely visual indicator that a slot is open for recipients to claim.
    @ViewBuilder
    private func staticHollowCircle() -> some View {
        Circle()
            .fill(Color.gray.opacity(0.08))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
            )
    }

    @ViewBuilder
    private func claimerBadge(for pid: PersonID) -> some View {
        let slotIdx = split.g.slotIndex(for: pid) ?? 0
        ColoredCircleBadge(
            text: BadgeColors.initials(from: displayName(for: slotIdx), fallback: slotIdx),
            color: BadgeColors.color(for: slotIdx)
        )
    }

    @ViewBuilder
    private func hollowClaimCircle() -> some View {
        // Dashed border (vs. solid + pulsing `+`) signals "this slot is open
        // for claiming" without competing with other UI animations. Filled
        // interior keeps the entire 28×28 area hit-testable.
        Circle()
            .fill(Color.gray.opacity(0.08))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        Color.blue.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                    )
            )
            .contentShape(Circle())
    }

    // MARK: - Tap-to-Claim handlers (recipient side)

    /// Row-tap handler for recipient claim flow. Mirrors compose's
    /// `handleItemRowTap` rules but with the active guest forced to the
    /// local user. Auto-claims a slot if the user isn't bound yet.
    private func handleItemRowTap(itemId: String) {
        guard ensureMySlotBound(),
              let wireIdx = items.firstIndex(where: { $0.id == itemId }) else { return }

        let partition = items[wireIdx].itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let myPID = myCanonicalPID

        let newPartition: ItemPartition = {
            switch partition {
            case .unclaimed:
                return .shares(denominator: 1, slots: [myPID])
            case .shares(let denom, var slots) where denom == 1:
                if slots.first == myPID { return .unclaimed }
                return partition
            case .shares(let denom, var slots):
                if let myIdx = slots.firstIndex(of: myPID) {
                    slots[myIdx] = nil
                    if slots.allSatisfy({ $0 == nil }) { return .unclaimed }
                    return .shares(denominator: denom, slots: slots)
                } else if let emptyIdx = slots.firstIndex(where: { $0 == nil }) {
                    slots[emptyIdx] = myPID
                    return .shares(denominator: denom, slots: slots)
                }
                return partition
            case .custom:
                return partition
            }
        }()

        applyPartitionUpdate(itemIndex: wireIdx, newPartition: newPartition)
    }

    private func handleCircleTap(itemId: String, shareIndex: Int) {
        guard ensureMySlotBound(),
              let wireIdx = items.firstIndex(where: { $0.id == itemId }) else { return }

        let partition = items[wireIdx].itemPartition(slotPersonIDs: canonicalSlotPIDs)
        let (denom, originalSlots) = SplitEditorViewModel.normalizedPartition(partition)
        guard originalSlots.indices.contains(shareIndex) else { return }

        let myPID = myCanonicalPID
        var slots = originalSlots
        if let existing = slots[shareIndex] {
            // Only the slot's owner can unclaim it — outsiders can't undo
            // someone else's claim. Safety net for callers that bypass the
            // view's interactivity guard.
            guard existing == myPID else { return }
            slots[shareIndex] = nil
        } else {
            // Claim, sender-locked: only the local user can claim, no
            // auto-rotate to other guests in the recipient flow.
            if slots.contains(myPID) { return }
            slots[shareIndex] = myPID
        }

        let newPartition: ItemPartition = slots.allSatisfy({ $0 == nil })
            ? .unclaimed
            : .shares(denominator: denom, slots: slots)

        applyPartitionUpdate(itemIndex: wireIdx, newPartition: newPartition)
    }

    /// Write the new partition into `items[itemIndex]` as wire fields and
    /// recompute `split.o`, but DON'T persist yet — accumulates as an
    /// unsaved local change so the recipient can claim multiple items
    /// without each tap firing a bubble retract. Committed via
    /// `commitClaimChanges()` when the user taps Save.
    private func applyPartitionUpdate(itemIndex: Int, newPartition: ItemPartition) {
        let wire = newPartition.wireFields(guests: split.g)
        items[itemIndex].rs = wire.rs
        items[itemIndex].sh = wire.sh
        items[itemIndex].cu = wire.cu

        let slotPIDs = canonicalSlotPIDs
        let mathItems = items.map { it -> (label: String, priceCents: Int, partition: ItemPartition) in
            (label: it.l,
             priceCents: it.p,
             partition: it.itemPartition(slotPersonIDs: slotPIDs))
        }
        split.o = SplitMath.computeOwedCents(
            mode: split.m,
            guests: split.g,
            payerIndex: split.pi,
            totalCents: split.tot,
            perGuestActive: nil,
            items: mathItems,
            feesCents: split.f ?? 0,
            discountCents: split.d ?? 0,
            taxCents: split.tx ?? 0,
            tipCents: split.tip ?? 0,
            claimMode: split.cl ?? false
        )

        hasUnsavedClaims = true
    }

    /// Commits all pending claim changes — single bubble retract + Firestore
    /// write. Replaces the per-tap broadcast that used to spam the chat with
    /// updates on every claim toggle.
    private func commitClaimChanges() {
        guard hasUnsavedClaims else { return }
        messageReceiptVM.persist(
            split: split, items: items,
            broadcast: true, action: .claimed, via: bus
        )
        hasUnsavedClaims = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Binds the local user to a slot if they aren't yet. Returns true on
    /// success. Mirrors the existing `claimSlot(at:)` logic: sets uid on the
    /// first slot without a uid, never overwrites the slot's stored name
    /// (per `feedback_slot_name_design.md`).
    @discardableResult
    private func ensureMySlotBound() -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        if split.g.contains(where: { $0.uid == myUid }) { return true }
        guard let emptyIdx = split.g.firstIndex(where: { $0.uid == nil }) else {
            return false
        }
        split.g[emptyIdx].uid = myUid
        billState = .joined

        // Make sure the user's display name is cached so cross-sender viewers
        // see it before the bubble propagates.
        let myName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
        if !myName.isEmpty {
            Task { try? await TabService.shared.createOrUpdateUser(userId: myUid, displayName: myName) }
        }
        removeCurrentUserFromIgnoredIfPresent()
        return true
    }
}

// MARK: - Totals box

private func isTipLabel(_ label: String) -> Bool {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("tip") || normalized.contains("gratuity")
}

struct TotalsBox: View {
    let receipt: ReceiptDisplay

    var body: some View {
        VStack(spacing: 10) {
            if receipt.shouldShowOnlyTotal {
                TotalsRow(label: "Total", value: receipt.totalCents)
            } else {
                TotalsRow(label: "Subtotal", value: receipt.subtotalCents)

                if receipt.lineItems.isEmpty {
                    if receipt.feesCents != 0 {
                        TotalsRow(label: "Fees", value: receipt.feesCents)
                    }
                    if receipt.discountCents != 0 {
                        TotalsRow(label: "Discount", value: -receipt.discountCents)
                    }
                    if receipt.taxCents != 0 {
                        TotalsRow(label: "Tax", value: receipt.taxCents)
                    }
                } else {
                    ForEach(receipt.lineItems.filter { !isTipLabel($0.label) }) { line in
                        TotalsRow(label: line.label, value: line.cents)
                    }
                }

                if receipt.tipCents != 0 {
                    TotalsRow(label: "Tip", value: receipt.tipCents)
                }

                Divider()

                TotalsRow(label: "Total", value: receipt.totalCents, bold: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct TotalsRow: View {
    let label: String
    let value: Int
    var bold: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
            Spacer()
            Text(ReceiptDisplay.money(value))
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
        }
    }
}

private struct SplitsSummaryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
