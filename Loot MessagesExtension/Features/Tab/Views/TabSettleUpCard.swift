//
//  TabSettleUpCard.swift
//  Loot
//
//  Reusable settle-up card: shows current user's simplified transactions with
//  Pay Now buttons. Used in SplitsSummaryView (tab receipt view) and
//  LootTabView (Payments tab).
//

import SwiftUI

// MARK: - Tab Settle-Up Card

struct TabSettleUpCard: View {
    let tabId: String
    let colorHex: String?
    var tabName: String? = nil
    /// Show "View Tab →" header button (for SplitsSummaryView context).
    var showViewTabButton: Bool = false
    var onViewTab: (() -> Void)? = nil
    var onSendSettlementCard: ((String, String, Int, String, String?) -> Void)? = nil
    var onSendRequestCard: ((String, String, Int, String?, RequestCardMetadata?) -> Void)? = nil
    /// Use UIApplication.openURL for Zelle web links when available.
    var openInSafari: ((URL) -> Void)? = nil
    var pendingPayRequest: PendingPayRequest? = nil
    var onConsumePendingPayRequest: (() -> Void)? = nil

    private let myId = KeychainHelper.getOrCreateUserId()
    @Environment(\.openURL) private var openURL

    @State private var balances: [String: Int] = [:]
    @State private var transactions: [DebtSimplifier.Transaction] = []
    @State private var memberNames: [String: String] = [:]
    @State private var creditorMethods: [String: [PaymentMethod]] = [:]
    @State private var members: [TabMember] = []
    @State private var loading = true
    @State private var paymentSheetTxn: DebtSimplifier.Transaction? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showViewTabButton, let onViewTab {
                Button(action: onViewTab) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Text(tabName ?? "Loot Tab")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("View Tab")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8).tint(.white)
                    Text("Loading tab balance…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            } else {
                let myBal = balances[myId] ?? 0
                let myTxns = transactions.filter { $0.from == myId || $0.to == myId }

                if myBal == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                        Text("You're all paid back!")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                } else {
                    HStack {
                        Text(myBal < 0 ? "To be sent" : "To be received")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(ReceiptDisplay.money(abs(myBal)))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                ForEach(myTxns) { txn in
                    transactionRow(txn: txn)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(colorHex.map { Color(hex: $0) } ?? Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .sheet(item: $paymentSheetTxn) { txn in
            let fromName = memberName(txn.from)
            let toName = memberName(txn.to)
            TabPayNowSheet(
                toName: toName,
                amountCents: txn.amountCents,
                methods: creditorMethods[txn.to] ?? [],
                tabColorHex: colorHex,
                onSelectMethod: { method in
                    // For Zelle: use the payer's own bank URL (opens their banking app)
                    // combined with the payee's stored QR data.
                    let effectiveBankURL: String?
                    if method.type == .zelle {
                        effectiveBankURL = savedPaymentMethods()
                            .first(where: { $0.type == .zelle })?.bankURL ?? method.bankURL
                    } else {
                        effectiveBankURL = method.bankURL
                    }
                    let deepLink = method.type.deepLinkURL(
                        identifier: method.identifier,
                        amountCents: txn.amountCents,
                        note: tabName ?? "Loot Tab",
                        bankURL: effectiveBankURL,
                        payeeName: toName,
                        zelleData: method.zelleData
                    )
                    onSendSettlementCard?(fromName, toName, txn.amountCents,
                                         method.type.displayName, colorHex)
                    if let url = deepLink {
                        openURL(url)
                    } else if method.type == .zelle {
                        UIPasteboard.general.string = method.identifier
                    }
                    Task { await recordSettlement(txn: txn, methodName: method.type.displayName) }
                }
            )
        }
        .task(id: tabId) { await load() }
        .onAppear {
            presentPendingRequestIfPossible()
        }
        .onChange(of: pendingPayRequest) { _, _ in
            presentPendingRequestIfPossible()
        }
    }

    // MARK: - Transaction Row

    @ViewBuilder
    private func transactionRow(txn: DebtSimplifier.Transaction) -> some View {
        let fromName = memberName(txn.from)
        let toName = memberName(txn.to)
        let displayFromName = txn.from == myId ? "You" : fromName
        let displayToName = txn.to == myId ? "You" : toName
        let fromIdx = memberIndex(txn.from)
        let toIdx = memberIndex(txn.to)
        let iOwe = txn.from == myId

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ColoredCircleBadge(
                    text: BadgeColors.initials(from: fromName, fallback: fromIdx),
                    color: BadgeColors.color(for: fromIdx)
                )
                Text(displayFromName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))

                ColoredCircleBadge(
                    text: BadgeColors.initials(from: toName, fallback: toIdx),
                    color: BadgeColors.color(for: toIdx)
                )
                Text(displayToName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                Spacer()

                Text(ReceiptDisplay.money(txn.amountCents))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
            }

            if iOwe, let methods = creditorMethods[txn.to], !methods.isEmpty {
                Button {
                    paymentSheetTxn = txn
                } label: {
                    Label("Pay Now", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colorHex.map { Color(hex: $0) } ?? .blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else if !iOwe {
                Button {
                    // creditorName = me (toName), debtorName = them (fromName)
                    onSendRequestCard?(
                        toName,
                        fromName,
                        txn.amountCents,
                        colorHex,
                        RequestCardMetadata(
                            receiptDocId: nil,
                            tabId: tabId,
                            creditorId: txn.to,
                            debtorId: txn.from
                        )
                    )
                } label: {
                    Label("Request", systemImage: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colorHex.map { Color(hex: $0) } ?? .blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(iOwe ? 0.15 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func memberName(_ memberId: String) -> String {
        if memberId == myId {
            let n = myDisplayNameFromDefaults()
            return n.isEmpty ? "Me" : n
        }
        return memberNames[memberId]
            ?? members.first(where: { $0.memberId == memberId })?.displayName
            ?? "Member"
    }

    private func memberIndex(_ memberId: String) -> Int {
        members.firstIndex(where: { $0.memberId == memberId }) ?? 0
    }

    // MARK: - Data Loading

    private func load() async {
        loading = true
        do {
            let freshMembers = (try? await TabService.shared.fetchTab(id: tabId))?.members ?? []
            let balancesResult = try await TabService.shared.computeTabBalances(
                tabId: tabId, members: freshMembers)
            let txns = DebtSimplifier.simplify(balances: balancesResult)

            var names: [String: String] = [:]
            let participants = Set(txns.flatMap { [$0.from, $0.to] }).filter { $0 != myId }
            for uid in participants {
                names[uid] = (try? await TabService.shared.fetchUserDisplayName(userId: uid))
                    ?? freshMembers.first(where: { $0.memberId == uid })?.displayName
            }

            var methods: [String: [PaymentMethod]] = [:]
            for txn in txns where txn.from == myId {
                if let pm = try? await TabService.shared.fetchPaymentMethods(userId: txn.to),
                   !pm.isEmpty {
                    methods[txn.to] = pm
                }
            }

            balances = balancesResult
            transactions = txns
            memberNames = names
            creditorMethods = methods
            members = freshMembers
            presentPendingRequestIfPossible(transactions: txns, creditorMethods: methods)
        } catch {
            print("[TabSettleUpCard] load failed: \(error)")
        }
        loading = false
    }

    private func presentPendingRequestIfPossible(
        transactions: [DebtSimplifier.Transaction]? = nil,
        creditorMethods: [String: [PaymentMethod]]? = nil
    ) {
        guard paymentSheetTxn == nil,
              let pending = pendingPayRequest,
              pending.tabId == tabId,
              let creditorId = pending.creditorId,
              let debtorId = pending.debtorId
        else { return }

        let candidateTransactions = transactions ?? self.transactions
        let candidateMethods = creditorMethods ?? self.creditorMethods
        guard let txn = candidateTransactions.first(where: {
            $0.to == creditorId && $0.from == debtorId && $0.amountCents == pending.amountCents
        }),
        let methods = candidateMethods[creditorId],
        !methods.isEmpty
        else { return }

        paymentSheetTxn = txn
        if !methods.isEmpty {
            onConsumePendingPayRequest?()
        }
    }

    private func recordSettlement(txn: DebtSimplifier.Transaction, methodName: String) async {
        let settlement = Settlement(
            createdBy: myId,
            fromMemberId: txn.from,
            toMemberId: txn.to,
            amountCents: txn.amountCents,
            note: "via \(methodName)"
        )
        do {
            try await TabService.shared.recordSettlement(settlement, forTab: tabId)
        } catch {
            print("[TabSettleUpCard] recordSettlement failed: \(error)")
        }
        loading = true
        await load()
    }
}
