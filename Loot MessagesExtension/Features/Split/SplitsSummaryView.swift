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

    private var isTabReceipt: Bool { uiModel.openedMessagePayload?.tid != nil }

    @State private var selectedIndex: Int = 0

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

    @Environment(\.openURL) private var openURL

    init(uiModel: LootUIModel, split: SplitPayload, items: [ReceiptItemPayload]) {
        self.uiModel = uiModel
        self._split = State(initialValue: split)
        self.items = items
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
        persistSplit()
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
    private func transactionRow(from: String, to: String, amount: Int, color: Color, guestIndex: Int, showPayButton: Bool = false) -> some View {
        let paid = isPaid(guestIndex: guestIndex)
        let editable = canTogglePaid(guestIndex: guestIndex)
        let canPay = showPayButton && !paid && !(payerPaymentMethods?.isEmpty ?? true)

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
                        .foregroundStyle(Color.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Guest row (reusable)

    @ViewBuilder
    private func guestRow(includedIdx i: Int, guestIdx gi: Int, showTransactions: Bool, included: [Int]) -> some View {
        let guestItems = itemsForSlot(i)
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
                        ForEach(0..<count, id: \.self) { j in
                            let gj = included[j]
                            if gj != gi {
                                transactionRow(
                                    from: displayName(for: gj),
                                    to: displayName(for: gi),
                                    amount: owed(for: gj),
                                    color: colorForSlot(gj),
                                    guestIndex: gj
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

    private func claimSlot(at guestIndex: Int) {
        let myUid = KeychainHelper.getOrCreateUserId()
        split.g[guestIndex].uid = myUid
        // Don't overwrite .n — that's the bill creator's manually-entered name.
        // Display name is resolved from uid via displayName(for:).
        billState = .joined
        persistSplit()

        // Select the newly claimed slot on the donut
        if let idx = myIncludedIndex {
            selectedIndex = idx
        }
    }

    private func unclaimSlot() {
        let myUid = KeychainHelper.getOrCreateUserId()
        if let gi = split.g.firstIndex(where: { $0.uid == myUid }) {
            split.g[gi].uid = nil
        }
        persistSplit()
    }

    private func persistSplit() {
        guard var payload = uiModel.openedMessagePayload,
              let docId = uiModel.openedMessageDocId else { return }

        payload.s = split
        uiModel.openedMessagePayload = payload

        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[SplitsSummaryView] Split persisted to \(docId)")
            } catch {
                print("[SplitsSummaryView] Failed to persist split: \(error)")
            }
        }
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
                let included = includedIndices
                let count = included.count
                let selectedIncludedSlot = max(0, min(selectedIndex, max(0, count - 1)))
                let selectedGuestIndex = count > 0 ? included[selectedIncludedSlot] : 0
                let selectedCents = owed(for: selectedGuestIndex)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                // Donut chart
                GeometryReader { geo in
                    let size = min(geo.size.width, 230)
                    let lineW: CGFloat = 30
                    let radius = size / 2 - lineW / 2
                    let dimmer = Color(white: 0.55)

                    ZStack {
                        Circle()
                            .stroke(Color(.secondarySystemBackground),
                                    style: .init(lineWidth: lineW, lineCap: .round))
                            .frame(width: size, height: size)

                        ForEach(0..<count, id: \.self) { i in
                            if safeTotal > 0 {
                                let gi = included[i]
                                let start = Double(sumBeforeIncludedSlot(i)) / Double(safeTotal)
                                let end = Double(sumThroughIncludedSlot(i)) / Double(safeTotal)
                                if end > start {
                                    Circle()
                                        .trim(from: start, to: end)
                                        .stroke(colorForSlot(gi),
                                                style: .init(lineWidth: lineW, lineCap: .round))
                                        .colorMultiply(i == selectedIndex ? .white : dimmer)
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: size, height: size)
                                }
//                                if i == 0 || selectedIndex != i {
//                                    let ang = -(.pi / 1.975) + (start * 2 * .pi)
//                                    let hx = center.x + handleRadius * cos(ang)
//                                    let hy = center.y + handleRadius * sin(ang)
//                                    Circle()
//                                        .fill(BadgeColors.color(for: colorGi))
//                                        .overlay(
//                                            Circle().stroke(BadgeColors.color(for: selectedIndex == 0 ? i : colorGi), lineWidth: 0.05)
//                                        )
//                                        .colorMultiply(colorIdx != selectedIndex ? dimmer : .white)
//                                        .frame(width: lineW, height: lineW)
//                                        .position(x: hx, y: hy)
//                                }
                            }
                        }

                        VStack(spacing: 6) {
                            Text("\(displayName(for: selectedGuestIndex)) owes")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(ReceiptDisplay.money(selectedCents))
                                .font(.system(size: 34, weight: .bold))

                            Text(percentText(selectedCents))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 240)

                // MARK: "You" section
                VStack(alignment: .leading, spacing: 8) {
                    Text("You")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    switch billState {
                    case .joined:
                        if let myIdx = myIncludedIndex {
                            let myGi = included[myIdx]

                            // Your card — no transaction arrows for tab receipts
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

                            if isTabReceipt {
                                let displayTab = uiModel.receiptTab ?? uiModel.activeTab
                                TabSettleUpCard(
                                    tabId: uiModel.openedMessagePayload?.tid ?? "",
                                    colorHex: displayTab?.colorHex,
                                    tabName: displayTab?.name,
                                    showViewTabButton: true,
                                    onViewTab: {
                                        // Make sure activeTab matches this receipt's tab before navigating.
                                        if let rt = uiModel.receiptTab {
                                            uiModel.activeTab = rt
                                        }
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            uiModel.currentScreen = .tabview
                                        }
                                    },
                                    onSendSettlementCard: uiModel.sendSettlementCard,
                                    onSendRequestCard: uiModel.sendRequestCard,
                                    openInSafari: uiModel.openInSafari
                                )
                            } else {
                                // Leave button
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        unclaimSlot()
                                        billState = .choosing
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

                    case .choosing:
                        // Prompt to pick a guest
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
                                    billState = .notInBill
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
                        // Not in bill — option to rejoin
                        VStack(spacing: 10) {
                            Text("You're not in this bill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    billState = .choosing
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("I'm in this bill")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.top, 15)

                // MARK: Others list
                VStack(alignment: .leading, spacing: 8) {
                    Text(billState == .joined ? "Others" : "Guests")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(spacing: 10) {
                        ForEach(0..<count, id: \.self) { i in
                            // Skip "me" if joined — already shown above
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

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        } // else
        } // Group
        .onAppear {
            let myUid = KeychainHelper.getOrCreateUserId()
            let alreadyClaimed = split.g.contains { $0.uid == myUid }

            if alreadyClaimed {
                billState = .joined
                if let myIdx = myIncludedIndex {
                    selectedIndex = myIdx
                }
            } else {
                // Not yet claimed — try auto-claim
                if split.m == .equally, let i = split.g.firstIndex(where: { $0.uid == nil }) {
                    claimSlot(at: i)
                } else if split.m != .equally {
                    let freeSlots = split.g.indices.filter { split.g[$0].uid == nil }
                    if freeSlots.count == 1 {
                        claimSlot(at: freeSlots[0])
                    } else {
                        billState = .choosing
                    }
                } else {
                    billState = .choosing
                }
            }
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
        .sheet(item: $paySheetInfo) { info in
            let note = uiModel.openedMessagePayload?.r.t ?? "Loot"
            let openInSafari = uiModel.openInSafari   // capture as local so inner closure holds it directly
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
                        if method.type == .zelle, let openInSafari {
                            openInSafari(url)
                        } else {
                            openURL(url)
                        }
                    } else if method.type == .zelle {
                        UIPasteboard.general.string = method.identifier
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        togglePaid(guestIndex: info.guestIndex)
                    }
                }
            )
        }
    }
}

