//
//  SettleUpExplainerSheet.swift
//  Loot
//
//  Bottom-sheet explainer for "How we do the math" on a tab.
//
//  Two modes:
//    • Generic — used when the local user has a $0 balance. Short
//      overview of split / tally / simplify.
//    • Personalized — used when the user owes or is owed. Walks
//      through their actual numbers: an animated coin-flow visual
//      showing the simplified transactions moving across the tab's
//      members, the per-member net balance list, and the user's
//      specific settlement rows with a "why" sentence.
//
//  Presented from the info button next to "To be sent" / "To be
//  received" in TabSettleUpCard. All loaded data (balances, members,
//  names, simplified transactions) is piped in directly so opening
//  the sheet is free — no extra Firestore round-trip.
//

import SwiftUI

struct SettleUpExplainerSheet: View {
    /// Local user's signed net balance in cents. Positive = owed,
    /// negative = owes, 0 = settled. `nil` falls back to generic mode.
    var myBalanceCents: Int? = nil
    /// Simplified transactions involving the local user (filtered
    /// upstream to `from == myId || to == myId`).
    var myTransactions: [DebtSimplifier.Transaction] = []
    /// Every simplified transaction across the whole tab — drives the
    /// coin-flow animation so the user sees all the money flow, not
    /// only their own slice.
    var allTransactions: [DebtSimplifier.Transaction] = []
    /// Snapshot of tab members for resolving names + indexes (badge
    /// colors). Inactive members are kept here for historical lookups
    /// — only `isActive` are surfaced visually.
    var members: [TabMember] = []
    /// uid → live display name. Same shape as TabSettleUpCard.memberNames.
    var memberNames: [String: String] = [:]
    /// Full per-member balance map for "who's net up / net down" — keyed
    /// by memberId. Pass `balances` from TabSettleUpCard.
    var balances: [String: Int] = [:]

    @Environment(\.dismiss) private var dismiss

    private let myId = KeychainHelper.getOrCreateUserId()

    private var isPersonalized: Bool {
        if let bal = myBalanceCents, bal != 0 { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isPersonalized, let bal = myBalanceCents {
                    personalizedBody(myBalance: bal)
                } else {
                    genericBody
                }
            }
            .padding(.horizontal, 20)
            // Generous top inset clears the drag indicator and the
            // top-trailing close button without overlap.
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary, Color(.tertiarySystemFill))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.trailing, 16)
            .accessibilityLabel("Close")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Personalized

    @ViewBuilder
    private func personalizedBody(myBalance: Int) -> some View {
        let absMoney = ReceiptDisplay.money(abs(myBalance))
        Text(myBalance < 0 ? "Why you owe \(absMoney)" : "Why you're owed \(absMoney)")
            .font(.system(size: 22, weight: .bold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

        // Coin-flow visual — animates a small `$` coin between each
        // pair of avatars in the simplified-transactions list. Drives
        // off `allTransactions`, not just `myTransactions`, so the
        // viewer sees the entire tab's money flow at a glance.
        if !allTransactions.isEmpty {
            CoinFlowVisual(
                members: members,
                balances: balances,
                transactions: allTransactions,
                myId: myId
            )
            .padding(.top, 4)
            .padding(.bottom, 4)
        }

        // Net balances
        VStack(alignment: .leading, spacing: 10) {
            Text("Net balances")
                .font(.system(size: 16, weight: .semibold))
            Text(myBalance < 0
                 ? "You paid less upfront than your share of receipts, so you're net down."
                 : "You paid more upfront than your share of receipts, so you're net up.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(sortedActiveMembersByBalance(), id: \.memberId) { member in
                    balanceRow(for: member)
                }
            }
        }

        // Settle the differences
        VStack(alignment: .leading, spacing: 10) {
            Text("Settle the differences")
                .font(.system(size: 16, weight: .semibold))

            let preface: String = {
                if myTransactions.isEmpty {
                    return "Your balance settles against the tab — no direct payments needed from you right now."
                }
                if myBalance < 0 {
                    return "Instead of paying back every receipt one-by-one, your balance settles to the people who covered the most."
                }
                return "Instead of every receipt paying you back individually, the people most net-down send you a single payment each."
            }()

            Text(preface)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !myTransactions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(myTransactions) { txn in
                        settlementRow(txn: txn)
                    }
                }

                let detail = settlementReasonText(myBalance: myBalance)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }

        Text("Balances recalculate as receipts are added, edited, or settled.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func settlementReasonText(myBalance: Int) -> String {
        guard let first = myTransactions.first else { return "" }
        let otherId = (first.from == myId) ? first.to : first.from
        let otherName = displayName(for: otherId)
        let otherBal = balances[otherId] ?? 0
        let otherCovered = otherBal > 0 ? ReceiptDisplay.money(otherBal) : nil
        let otherOwes = otherBal < 0 ? ReceiptDisplay.money(abs(otherBal)) : nil

        if myBalance < 0 {
            if let otherCovered {
                return "\(otherName) covered \(otherCovered) more than their share, so paying them shortcuts the longest chain."
            }
            return "Routing your payments to \(otherName) keeps the total number of settlements low."
        } else {
            if let otherOwes {
                return "\(otherName) is net down \(otherOwes), so paying you settles them in one move."
            }
            return "Routing payments from \(otherName) keeps the total number of settlements low."
        }
    }

    @ViewBuilder
    private func balanceRow(for member: TabMember) -> some View {
        let isMe = member.memberId == myId
        let bal = balances[member.memberId] ?? member.balanceCents
        let badgeIdx = members.firstIndex(where: { $0.memberId == member.memberId }) ?? 0
        let name = isMe ? "You" : displayName(for: member.memberId)
        HStack(spacing: 10) {
            ColoredCircleBadge(
                text: BadgeColors.initials(from: member.displayName, fallback: badgeIdx),
                color: BadgeColors.color(for: badgeIdx)
            )
            Text(name)
                .font(.system(size: 14, weight: isMe ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text((bal > 0 ? "+" : bal < 0 ? "−" : "") + ReceiptDisplay.money(abs(bal)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(bal > 0 ? Color.green : bal < 0 ? Color.red : Color.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(isMe ? Color.blue.opacity(0.08) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func settlementRow(txn: DebtSimplifier.Transaction) -> some View {
        let iOwe = (txn.from == myId)
        let otherId = iOwe ? txn.to : txn.from
        let otherIdx = members.firstIndex(where: { $0.memberId == otherId }) ?? 0
        let otherName = displayName(for: otherId)
        HStack(spacing: 10) {
            ColoredCircleBadge(
                text: BadgeColors.initials(from: otherName, fallback: otherIdx),
                color: BadgeColors.color(for: otherIdx)
            )
            Text(iOwe ? "You pay \(otherName)" : "\(otherName) pays you")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text(ReceiptDisplay.money(txn.amountCents))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(iOwe ? Color.red : Color.green)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sortedActiveMembersByBalance() -> [TabMember] {
        let active = members.filter(\.isActive)
        return active.sorted { lhs, rhs in
            let lb = balances[lhs.memberId] ?? lhs.balanceCents
            let rb = balances[rhs.memberId] ?? rhs.balanceCents
            return lb > rb
        }
    }

    private func displayName(for memberId: String) -> String {
        if memberId == myId {
            let n = myDisplayNameFromDefaults()
            return n.isEmpty ? "Me" : n
        }
        if let cached = memberNames[memberId], !cached.isEmpty { return cached }
        return members.first(where: { $0.memberId == memberId })?.displayName ?? "Member"
    }

    // MARK: - Generic ($0 balance / fallback)

    @ViewBuilder
    private var genericBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How we do the math")
                .font(.system(size: 22, weight: .bold))
            Text("You're all settled up — here's how we keep things even when receipts come in.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }

        bullet(
            icon: "person.2.fill",
            title: "Split things automatically",
            body: "Every receipt gets split among the people the sender includes — even, by items, or custom."
        )
        bullet(
            icon: "list.number",
            title: "Tally up the totals",
            body: "Each member's running balance updates as receipts are added, edited, or settled."
        )
        bullet(
            icon: "arrow.triangle.merge",
            title: "Settle the fewest payments",
            body: "When someone needs to pay, we collapse chains of debt into the fewest direct payments. If A owes B and B owes C the same amount, A just pays C."
        )

        Text("Balances recalculate automatically when anyone edits, settles, or adds a receipt.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Coin flow visual

/// Animated horizontal strip showing the tab's active members and tiny
/// `$` coins moving between each simplified transaction's debtor and
/// creditor avatar. Built on `TimelineView(.animation)` so coins
/// animate at the display's refresh rate without a SwiftUI animation
/// state, and so the strip auto-pauses when off-screen.
private struct CoinFlowVisual: View {
    let members: [TabMember]
    let balances: [String: Int]
    let transactions: [DebtSimplifier.Transaction]
    let myId: String

    private let avatarSize: CGFloat = 36
    private let spacing: CGFloat = 14
    private let coinSize: CGFloat = 18
    private let cycleDuration: TimeInterval = 2.6

    /// Active members sorted ascending by balance so net-debtors sit on
    /// the left and net-creditors sit on the right. The animated coins
    /// then read as "money moves left → right" — visually reinforces
    /// the simplification.
    private var sortedMembers: [TabMember] {
        members.filter(\.isActive).sorted { lhs, rhs in
            let lb = balances[lhs.memberId] ?? lhs.balanceCents
            let rb = balances[rhs.memberId] ?? rhs.balanceCents
            return lb < rb
        }
    }

    var body: some View {
        let count = sortedMembers.count
        return TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    HStack(spacing: spacing) {
                        ForEach(sortedMembers, id: \.memberId) { member in
                            memberAvatar(member)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    ForEach(Array(transactions.enumerated()), id: \.offset) { idx, txn in
                        if let dot = coinPosition(
                            txn: txn,
                            elapsed: elapsed,
                            idx: idx,
                            width: geo.size.width,
                            height: geo.size.height,
                            count: count
                        ) {
                            coinView()
                                .opacity(dot.opacity)
                                .position(x: dot.x, y: dot.y)
                        }
                    }
                }
            }
        }
        .frame(height: avatarSize + 16)
    }

    private func memberAvatar(_ member: TabMember) -> some View {
        let idx = members.firstIndex(where: { $0.memberId == member.memberId }) ?? 0
        let isMe = member.memberId == myId
        return ZStack {
            Circle()
                .fill(BadgeColors.color(for: idx).opacity(0.85))
            Text(BadgeColors.initials(from: member.displayName, fallback: idx))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            if isMe {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
    }

    private func coinView() -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.86, blue: 0.32),
                                 Color(red: 0.95, green: 0.62, blue: 0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
            Text("$")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: coinSize, height: coinSize)
    }

    private struct CoinPos {
        let x: CGFloat
        let y: CGFloat
        let opacity: Double
    }

    /// Computes a coin's position + opacity at `elapsed`. Each coin gets
    /// a staggered phase offset so they don't all move in unison.
    /// Coins arc slightly upward at the midpoint so adjacent flows
    /// don't visually overlap into a flat line.
    private func coinPosition(
        txn: DebtSimplifier.Transaction,
        elapsed: TimeInterval,
        idx: Int,
        width: CGFloat,
        height: CGFloat,
        count: Int
    ) -> CoinPos? {
        guard count > 0 else { return nil }
        guard let fromIdx = sortedMembers.firstIndex(where: { $0.memberId == txn.from }),
              let toIdx = sortedMembers.firstIndex(where: { $0.memberId == txn.to })
        else { return nil }
        guard fromIdx != toIdx else { return nil }

        let totalWidth = CGFloat(count) * avatarSize + CGFloat(max(0, count - 1)) * spacing
        let leftMargin = max(0, (width - totalWidth) / 2)
        let fromX = leftMargin + CGFloat(fromIdx) * (avatarSize + spacing) + avatarSize / 2
        let toX = leftMargin + CGFloat(toIdx) * (avatarSize + spacing) + avatarSize / 2

        // Stagger each coin by an equal slice of the cycle so the strip
        // never feels empty AND never feels swarmed.
        let txnCount = max(1, transactions.count)
        let stagger = Double(idx) * (cycleDuration / Double(txnCount))
        var rawPhase = (elapsed - stagger).truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        if rawPhase < 0 { rawPhase += 1 }

        let progress = CGFloat(rawPhase)
        let x = fromX + (toX - fromX) * progress
        // Small upward arc — peak at mid-phase, returns to baseline at
        // both endpoints so the coin clearly leaves and lands on the
        // avatar rather than floating above it.
        let arcHeight: CGFloat = 8
        let y = height / 2 - arcHeight * CGFloat(sin(rawPhase * .pi))

        // Fade in/out at the boundaries so coins don't pop at the
        // exact avatar position.
        let opacity: Double = {
            let fadeIn = 0.12
            let fadeOut = 0.88
            if rawPhase < fadeIn { return rawPhase / fadeIn }
            if rawPhase > fadeOut { return (1.0 - rawPhase) / (1.0 - fadeOut) }
            return 1.0
        }()

        return CoinPos(x: x, y: y, opacity: opacity)
    }
}
