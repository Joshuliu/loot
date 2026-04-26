//
//  SplitsSummaryView.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI
import UIKit

struct SplitsSummaryView: View {
    @ObservedObject var uiModel: LootUIModel
    @State private var split: SplitPayload
    let items: [ReceiptItemPayload]  // Receipt items with responsibleSlots
    let onEditSplit: (() -> Void)?
    let onEditReceipt: (() -> Void)?
    let onRemoveFromTab: (() -> Void)?
    let onClose: (() -> Void)?
    let onRequestCollapse: (() -> Void)?

    private var canEdit: Bool {
        guard let payload = uiModel.openedMessagePayload else { return false }
        let myUid = KeychainHelper.getOrCreateUserId()
        return payload.canEdit(myUid: myUid, userTabs: uiModel.userTabs)
    }

    private var isTabReceipt: Bool { uiModel.openedMessagePayload?.tid != nil }

    @State private var selectedIndex: Int? = nil

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
        uiModel: LootUIModel,
        split: SplitPayload,
        items: [ReceiptItemPayload],
        onEditSplit: (() -> Void)? = nil,
        onEditReceipt: (() -> Void)? = nil,
        onRemoveFromTab: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onRequestCollapse: (() -> Void)? = nil
    ) {
        self.uiModel = uiModel
        self._split = State(initialValue: split)
        self.items = items
        self.onEditSplit = onEditSplit
        self.onEditReceipt = onEditReceipt
        self.onRemoveFromTab = onRemoveFromTab
        self.onClose = onClose
        self.onRequestCollapse = onRequestCollapse
    }

    private var receipt: ReceiptDisplay? {
        uiModel.currentReceipt
    }

    private var captureImage: UIImage? {
        uiModel.scanImageCropped ?? uiModel.scanImageOriginal
    }

    private var currentBillId: String? {
        uiModel.openedMessageDocId ?? uiModel.openedMessagePayload?.r.id
    }

    private var hasIgnoredListForBill: Bool {
        uiModel.hasIgnoredUUIDsList(for: currentBillId)
    }

    private var hasClaimableSlots: Bool {
        includedIndices.contains { split.g.indices.contains($0) && split.g[$0].uid == nil }
    }

    private func addCurrentUserToIgnored() {
        let myUid = KeychainHelper.getOrCreateUserId()
        uiModel.addIgnoredUUID(myUid, for: currentBillId)
    }

    private func removeCurrentUserFromIgnoredIfPresent() {
        let myUid = KeychainHelper.getOrCreateUserId()
        uiModel.removeIgnoredUUID(myUid, for: currentBillId)
    }

    private func isCurrentUserIgnored() -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        return uiModel.isIgnoredUUID(myUid, for: currentBillId)
    }

    private func unclaimCurrentUserIfNeeded() -> Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        guard let gi = split.g.firstIndex(where: { $0.uid == myUid }) else { return false }
        split.g[gi].uid = nil
        return true
    }

    private var headerTitle: String {
        receipt?.title ?? uiModel.openedMessagePayload?.r.t ?? "Receipt"
    }

    private var headerDateText: String {
        receipt?.dateText ?? "—"
    }

    private var associatedTab: LootTab? {
        if let receiptTab = uiModel.receiptTab {
            return receiptTab
        }
        if let payloadTab = uiModel.openedMessagePayload?.tab {
            return LootTab.minimal(id: payloadTab.id, name: payloadTab.n, colorHex: payloadTab.c)
        }
        if isTabReceipt {
            return uiModel.activeTab
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
        if let associatedTab {
            uiModel.activeTab = associatedTab
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
              let pending = uiModel.pendingPayRequest,
              let docId = uiModel.openedMessageDocId,
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
        uiModel.pendingPayRequest = nil
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
                    uiModel.sendRequestCard?(
                        to,
                        from,
                        amount,
                        nil,
                        RequestCardMetadata(
                            receiptDocId: uiModel.openedMessageDocId,
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

        // Embed the joiner's local display name into the wire payload when
        // the slot's name is empty. The sender's view falls through to
        // g.n when uidDisplayNames hasn't been populated yet (the recipient's
        // Firestore user doc may not exist or may not have synced), so
        // without this, the sender keeps seeing "Guest N" until a separate
        // round-trip resolves the name. We deliberately only fill empty
        // slots — a manually-entered name from the bill creator wins.
        let trimmedExisting = split.g[guestIndex].n.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExisting.isEmpty {
            let myName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            if !myName.isEmpty {
                split.g[guestIndex].n = myName
            }
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
        guard var payload = uiModel.openedMessagePayload,
              let docId = uiModel.openedMessageDocId else { return }

        payload.s = split
        uiModel.openedMessagePayload = payload
        if broadcast {
            uiModel.sendBillUpdate?(payload, docId, action)
        }

        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[SplitsSummaryView] Split persisted to \(docId)")
            } catch {
                print("[SplitsSummaryView] Failed to persist split: \(error)")
            }
        }
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
                VStack(spacing: 0) {
                        if uiModel.itemsLoadingState.isLoading {
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
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.label)
                                            .font(.system(size: 16, weight: .semibold))
                                            .lineLimit(1)

                                        Text(ReceiptDisplay.money(item.priceCents))
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 8)

                                    HStack(spacing: 6) {
                                        // Resolve the slot index from the canonical
                                        // assigneeIDs, then defer to the local
                                        // displayName(for idx:) helper so the badge
                                        // text picks up the Firestore-cached name
                                        // for joined members and `myDisplayName`
                                        // for the local user. The wire payload's
                                        // g.n alone would be stale for slots that
                                        // joined after the bill was sent.
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
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

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
        }
        .onChange(of: uiModel.openedMessagePayload?.s) { _, latestSplit in
            guard let latestSplit, latestSplit != split else { return }
            split = latestSplit
            reconcileClaimState()
        }
        .task {
            let myUid = KeychainHelper.getOrCreateUserId()

            // Check tab membership — non-members see a locked view
            if isTabReceipt, let tabId = uiModel.openedMessagePayload?.tid {
                if uiModel.userTabs.contains(where: { $0.id == tabId }) {
                    tabMembershipState = .member
                } else {
                    let tab = try? await TabService.shared.fetchTab(id: tabId)
                    tabMembershipState = tab?.memberIds.contains(myUid) == true ? .member : .notMember
                }
            } else {
                tabMembershipState = .member
            }

            // Fetch display names for all uids in the guest list (except self)
            let otherUids = Set(split.g.compactMap(\.uid)).filter { $0 != myUid && !$0.isEmpty }
            for uid in otherUids {
                do {
                    if let name = try await TabService.shared.fetchUserDisplayName(userId: uid) {
                        uidDisplayNames[uid] = name
                    }
                } catch {
                    print("[SplitsSummaryView] Failed to fetch name for \(uid): \(error)")
                }
            }

            // Fetch payer's payment methods (only if I'm not the payer, and not a tab receipt)
            if !isTabReceipt, let payerUid = split.g[split.pi].uid, payerUid != myUid {
                payerPaymentMethods = try? await TabService.shared.fetchPaymentMethods(userId: payerUid)
            }

        }
        .onChange(of: uiModel.openedMessagePayload?.s) { _, newSplit in
            if let newSplit {
                split = newSplit
            }
        }
        .onChange(of: payerPaymentMethods) { _, _ in
            presentPendingRequestIfPossible()
        }
        .sheet(item: $paySheetInfo) { info in
            let note = uiModel.openedMessagePayload?.r.t ?? "Loot"
            let sendSettlement = uiModel.sendSettlementCard
            TabPayNowSheet(
                toName: info.toName,
                amountCents: info.amountCents,
                methods: info.methods,
                tabColorHex: nil,
                onSelectMethod: { method in
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
                    sendSettlement?(info.fromName, info.toName,
                                    info.amountCents, method.type.displayName, nil)
                    if let url = deepLink {
                        openURL(url)
                    } else if method.type == .zelle {
                        UIPasteboard.general.string = method.identifier
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        togglePaid(guestIndex: info.guestIndex)
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
    }
}

// MARK: - Totals box

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
                    ForEach(receipt.lineItems) { line in
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
