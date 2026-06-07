//
//  MemberSettleUpSheet.swift
//  Loot
//
//  Tap-to-view sheet for a single tab member's settle-up state.
//  Opens from the members list in LootTabView.
//
//  Small detent (.medium): a one-line summary like "Alice sends $25 to
//                          get even" plus the first transactions so the
//                          user can act without dragging up.
//  Large detent (.large) : the full transactions list filtered to those
//                          involving the selected member.
//
//  Transactions where the local user is the debtor get a Pay Now button;
//  where the local user is the creditor get a Request button. Rows that
//  don't involve the local user (e.g. Alice → Bob, viewed by Carol)
//  stay read-only.
//
//  Self-contained: loads its own balances / transactions / names /
//  payment methods via TabService so callers don't have to hoist state
//  up from TabSettleUpCard.
//

import SwiftUI

struct MemberSettleUpSheet: View {
    let tabId: String
    let tabName: String?
    let colorHex: String?
    /// memberId of the tab member whose settle-up we're displaying. May
    /// be the local user (in which case Pay/Request buttons appear on
    /// every involved row) or any other tab member.
    let memberId: String

    // Callbacks forwarded down from LootTabView, same contracts as
    // TabSettleUpCard so the Pay Now / Request paths behave identically.
    var onSendSettlementCard: ((String, String, Int, String, String?) -> Void)? = nil
    var onApplePayHandoff: ((String, String, Int, String?) -> Void)? = nil
    var onSendRequestCard: ((String, String, Int, String?, RequestCardMetadata?) -> Void)? = nil
    var openInSafari: ((URL) -> Void)? = nil
    var onRequestCollapse: (() -> Void)? = nil
    var onApplePayPending: ((String, Int, String?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var members: [TabMember] = []
    @State private var balances: [String: Int] = [:]
    @State private var transactions: [DebtSimplifier.Transaction] = []
    @State private var memberNames: [String: String] = [:]
    @State private var creditorMethods: [String: [PaymentMethod]] = [:]
    @State private var loading = true
    @State private var paymentSheetTxn: DebtSimplifier.Transaction? = nil

    private let myId = KeychainHelper.getOrCreateUserId()

    private var iAmMember: Bool { memberId == myId }
    private var memberName: String {
        if iAmMember {
            let n = myDisplayNameFromDefaults()
            return n.isEmpty ? "Me" : n
        }
        if let cached = memberNames[memberId], !cached.isEmpty { return cached }
        return members.first(where: { $0.memberId == memberId })?.displayName ?? "Member"
    }
    private var memberBalanceCents: Int {
        balances[memberId] ?? (members.first(where: { $0.memberId == memberId })?.balanceCents ?? 0)
    }

    /// All simplified transactions involving the selected member, sorted
    /// "sending" first then "receiving", largest amount first within each
    /// group.
    private var memberTxns: [DebtSimplifier.Transaction] {
        transactions
            .filter { $0.from == memberId || $0.to == memberId }
            .sorted { lhs, rhs in
                let lFrom = (lhs.from == memberId)
                let rFrom = (rhs.from == memberId)
                if lFrom != rFrom { return lFrom }
                return lhs.amountCents > rhs.amountCents
            }
    }

    private var headerSummary: String {
        let name = iAmMember ? "You" : memberName
        let verb = iAmMember ? "" : "s"
        if memberBalanceCents == 0 {
            return iAmMember ? "You're all settled up" : "\(name) is all settled up"
        }
        if memberBalanceCents < 0 {
            return "\(name) send\(verb) \(ReceiptDisplay.money(abs(memberBalanceCents))) to get even"
        }
        return "\(name) receive\(verb) \(ReceiptDisplay.money(memberBalanceCents)) to get even"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 24)
                        Spacer()
                    }
                } else if memberTxns.isEmpty {
                    Text(memberBalanceCents == 0
                         ? "No outstanding transactions."
                         : "No simplified transactions to show.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    VStack(spacing: 10) {
                        ForEach(memberTxns) { txn in
                            transactionRow(txn: txn)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $paymentSheetTxn) { txn in
            let fromName = displayName(for: txn.from)
            let toName = displayName(for: txn.to)
            TabPayNowSheet(
                toName: toName,
                amountCents: txn.amountCents,
                methods: creditorMethods[txn.to] ?? [],
                tabColorHex: colorHex,
                onSelectMethod: { method in
                    handlePay(method: method, txn: txn, fromName: fromName, toName: toName)
                }
            )
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ColoredCircleBadge(
                    text: BadgeColors.initials(from: memberName, fallback: memberIndex),
                    color: BadgeColors.color(for: memberIndex)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(memberName + (iAmMember ? " (You)" : ""))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    if let tabName, !tabName.isEmpty {
                        Text(tabName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(ReceiptDisplay.money(abs(memberBalanceCents)))
                    .font(.system(size: 17, weight: .bold))
                    // Pin the branches to `Color` — without explicit
                    // types, Swift infers `.secondary` as
                    // HierarchicalShapeStyle and `.green` / `.red` as
                    // Color, then refuses to unify them.
                    .foregroundStyle(memberBalanceCents == 0
                                     ? Color.secondary
                                     : (memberBalanceCents > 0 ? Color.green : Color.red))
            }
            Text(headerSummary)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func transactionRow(txn: DebtSimplifier.Transaction) -> some View {
        let fromName = displayName(for: txn.from)
        let toName = displayName(for: txn.to)
        let displayFromName = txn.from == myId ? "You" : fromName
        let displayToName = txn.to == myId ? "You" : toName
        let fromIdx = memberIndexFor(txn.from)
        let toIdx = memberIndexFor(txn.to)
        let iOwe = txn.from == myId
        let iAmCreditor = txn.to == myId
        let canPay = iOwe && !(creditorMethods[txn.to]?.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ColoredCircleBadge(
                    text: BadgeColors.initials(from: fromName, fallback: fromIdx),
                    color: BadgeColors.color(for: fromIdx)
                )
                Text(displayFromName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                ColoredCircleBadge(
                    text: BadgeColors.initials(from: toName, fallback: toIdx),
                    color: BadgeColors.color(for: toIdx)
                )
                Text(displayToName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(ReceiptDisplay.money(txn.amountCents))
                    .font(.system(size: 13, weight: .bold))
            }

            // Action buttons only render when the local user is part of
            // the transaction. Viewing someone else's row (Alice → Bob,
            // as Carol) stays read-only.
            if canPay {
                Button {
                    paymentSheetTxn = txn
                } label: {
                    Label("Pay Now", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colorHex.map { Color(hex: $0) } ?? .blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else if iAmCreditor {
                Button {
                    onSendRequestCard?(
                        toName,    // creditor (me)
                        fromName,  // debtor (them)
                        txn.amountCents,
                        colorHex,
                        RequestCardMetadata(
                            receiptDocId: nil,
                            tabId: tabId,
                            creditorId: txn.to,
                            debtorId: txn.from
                        )
                    )
                    dismiss()
                } label: {
                    Label("Request", systemImage: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colorHex.map { Color(hex: $0) } ?? .blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private var memberIndex: Int {
        members.firstIndex(where: { $0.memberId == memberId }) ?? 0
    }

    private func memberIndexFor(_ uid: String) -> Int {
        members.firstIndex(where: { $0.memberId == uid }) ?? 0
    }

    private func displayName(for uid: String) -> String {
        if uid == myId {
            let n = myDisplayNameFromDefaults()
            return n.isEmpty ? "Me" : n
        }
        if let cached = memberNames[uid], !cached.isEmpty { return cached }
        return members.first(where: { $0.memberId == uid })?.displayName ?? "Member"
    }

    // MARK: - Data load

    private func load() async {
        loading = true
        do {
            let freshMembers = (try? await TabService.shared.fetchTab(id: tabId))?.members ?? []
            let balancesResult = try await TabService.shared.computeTabBalances(
                tabId: tabId, members: freshMembers)
            let txns = DebtSimplifier.simplify(balances: balancesResult)

            // Resolve display names for everyone who appears in the
            // filtered list (txns plus the selected member themselves)
            // so rows never fall back to a raw uuid.
            var names: [String: String] = [:]
            let participants = Set(txns.flatMap { [$0.from, $0.to] } + [memberId])
                .filter { $0 != myId }
            for uid in participants {
                names[uid] = (try? await TabService.shared.fetchUserDisplayName(userId: uid))
                    ?? freshMembers.first(where: { $0.memberId == uid })?.displayName
            }

            // Only the local user can take action, so payment methods
            // are fetched only for creditors the local user owes.
            var methods: [String: [PaymentMethod]] = [:]
            for txn in txns where txn.from == myId {
                if let pm = try? await TabService.shared.fetchPaymentMethods(userId: txn.to),
                   !pm.isEmpty {
                    methods[txn.to] = pm
                }
            }

            members = freshMembers
            balances = balancesResult
            transactions = txns
            memberNames = names
            creditorMethods = methods
        } catch {
            print("[MemberSettleUpSheet] load failed: \(error)")
        }
        loading = false
    }

    // MARK: - Pay flow

    private func handlePay(
        method: PaymentMethod,
        txn: DebtSimplifier.Transaction,
        fromName: String,
        toName: String
    ) {
        if method.type == .applePay {
            onApplePayPending?(toName, txn.amountCents, colorHex)
            onApplePayHandoff?(fromName, toName, txn.amountCents, colorHex)
            onRequestCollapse?()
            Task { await recordSettlement(txn: txn, methodName: method.type.displayName) }
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
            amountCents: txn.amountCents,
            note: tabName ?? "Loot Tab",
            bankURL: effectiveBankURL,
            payeeName: toName,
            zelleData: method.zelleData
        )
        onSendSettlementCard?(fromName, toName, txn.amountCents,
                             method.type.displayName, colorHex)
        if let url = deepLink {
            if let openInSafari { openInSafari(url) } else { openURL(url) }
        } else if method.type == .zelle {
            UIPasteboard.general.string = method.identifier
        }
        Task { await recordSettlement(txn: txn, methodName: method.type.displayName) }
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
            print("[MemberSettleUpSheet] recordSettlement failed: \(error)")
        }
        await load()
    }
}
