//
//  TabView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import SwiftUI
import FirebaseFirestore

struct LootTabView: View {
    @Binding var tabName: String

    var onUpload: () -> Void
    var onScan: () -> Void
    var onFill: () -> Void

    // Tab-related props
    var activeTab: LootTab? = nil
    var userTabs: [LootTab] = []
    var conversationMemberIds: Set<String> = []
    var isExpanded: Bool = false
    var onStartTab: (() -> Void)? = nil
    var onSelectTab: ((LootTab) -> Void)? = nil
    var onTabNameTapped: (() -> Void)? = nil
    var onClearTab: (() -> Void)? = nil
    var onInviteMembers: (() -> Void)? = nil
    var onAccountTapped: (() -> Void)? = nil
    var onTabUpdated: ((LootTab) -> Void)? = nil
    var onTabLeft: (() -> Void)? = nil
    var onTabDeleted: (() -> Void)? = nil
    var onPreviewSplits: ((TabReceipt) -> Void)? = nil
    var onSendSettlementCard: ((String, String, Int, String, String?) -> Void)? = nil
    var onSendRequestCard: ((String, String, Int, String?) -> Void)? = nil
    var openInSafari: ((URL) -> Void)? = nil
    let onRequestCollapse: () -> Void
    
    @AppStorage(DefaultsKeys.myDisplayName) private var myDisplayName: String = ""
    @State private var showingTabSwitcher: Bool = false
    @State private var showingAddReceiptPanel: Bool = false
    @State private var showingTabSettings: Bool = false
    @State private var selectedSegment: Int = 0
    @State private var receipts: [TabReceipt] = []
    @State private var settlements: [Settlement] = []
    @State private var paymentsLoading: Bool = false

    private var sortedUserTabs: [LootTab] {
        guard !conversationMemberIds.isEmpty else { return userTabs }
        return userTabs.sorted { a, b in
            let aScore = a.memberIds.filter { conversationMemberIds.contains($0) }.count
            let bScore = b.memberIds.filter { conversationMemberIds.contains($0) }.count
            return aScore > bScore
        }
    }

    private var resolvedHeaderColor: Color {
        Color(hex: activeTab?.colorHex ?? TabColorOptions.defaultHex)
    }

    private var isColoredCompact: Bool {
        activeTab != nil && (!isExpanded || showingAddReceiptPanel)
    }
    
    var initials: String {
        let components = myDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else if let first = components.first {
            return String(first.prefix(1)).uppercased()
        }
        return "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top section: the whole compact view, shrinks to just the bar when expanded.
            // Its color never changes — only depends on which tab is selected.
            VStack(spacing: 0) {
                if !isExpanded || activeTab == nil || showingAddReceiptPanel {
                    compactInnerContent
                        .padding(.vertical, 20)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.25).delay(0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        ))
                    if !isExpanded {
                        Spacer()
                    }
                }
                tabBar
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeTab != nil)
            .background(
                activeTab != nil
                    ? resolvedHeaderColor
                    : Color.clear
            )

            // Bottom section: expanded content slides up from below
            if isExpanded && !showingAddReceiptPanel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        expandedTabContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isExpanded)
        .overlay(alignment: .topTrailing) {
            Button(action: { onAccountTapped?() }) {
                Text(initials)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(activeTab != nil ? resolvedHeaderColor : .white)
                    .frame(width: 38, height: 38)
                    .background(activeTab != nil ? Color.white : Color.black)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 16)
        }
        .sheet(isPresented: $showingTabSettings) {
            if let tab = activeTab {
                TabSettingsView(
                    tab: tab,
                    onSave: { updatedTab in onTabUpdated?(updatedTab) },
                    onLeft: { onTabLeft?() },
                    onDeleted: { onTabDeleted?() }
                )
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            if !newValue { showingAddReceiptPanel = false }
        }
        .task(id: activeTab?.id) {
            await loadPayments()
        }
    }

    // MARK: - Compact Inner Content (title + buttons + labels)

    private var compactInnerContent: some View {
        VStack(spacing: 20) {
            HStack {
                Text(activeTab != nil ? "Add Receipt to Tab" : "Split New Receipt")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(isColoredCompact ? .white : .primary)
                    .padding(.horizontal, 24)
                Spacer()
            }

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Button(action: onUpload) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 32)

                    Button(action: onScan) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 32)

                    Button(action: onFill) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                            .offset(y: -4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(18)

                HStack(spacing: 0) {
                    Text("Upload")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isColoredCompact ? .white.opacity(0.85) : .primary)
                        .frame(maxWidth: .infinity)

                    Text("Scan")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isColoredCompact ? .white.opacity(0.85) : .primary)
                        .frame(maxWidth: .infinity)

                    Text("Enter Total")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isColoredCompact ? .white.opacity(0.85) : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Tab Bar (pill + circle, animates between compact/expanded layout)

    var tabBar: some View {
        ZStack {
            // Tab pill — left-center in compact, bottom-left in expanded
            Button(action: {
                if showingAddReceiptPanel {
                    showingAddReceiptPanel = false
                } else {
                    onTabNameTapped?()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 18))
                    Text((!showingTabSwitcher ? activeTab?.name : nil) ?? "Loot Tabs")
                        .font(.system(size: 24, weight: .semibold))
                        .scaleEffect(isExpanded ? 1.0 : 20.0 / 24.0, anchor: .leading)
                        .lineLimit(1)
                    if activeTab != nil {
                            Button(action: { onClearTab?() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(activeTab != nil ? .white.opacity(0.5) : .secondary)
                            }
                            .buttonStyle(.plain)
                    } else if !isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(activeTab != nil ? .white.opacity(0.5) : .secondary)
                    }
                }
                .foregroundColor(activeTab != nil ? .white : .primary)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    activeTab != nil ?
                        Color.white.opacity(isExpanded ? 0 : 0.15) :
                        isExpanded ?
                            Color.clear :
                            Color(UIColor.secondarySystemBackground)
                )
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isExpanded ? .bottomLeading : .leading)

            // Tab settings button (only when a tab is active)
            if activeTab != nil {
                Button(action: { showingTabSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: activeTab == nil || showingAddReceiptPanel || !isExpanded ? .trailing : .topTrailing)
                .padding(.horizontal, activeTab == nil || showingAddReceiptPanel || !isExpanded ? 0 : 48)
//                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: activeTab == nil || showingAddReceiptPanel || !isExpanded ? 66 : 120)
        .frame(maxWidth: .infinity)
        .background(
            activeTab != nil
                ? resolvedHeaderColor
                : Color.clear
        )
    }

    // MARK: - Expanded Tab Content

    @ViewBuilder
    private var expandedTabContent: some View {
        if let tab = activeTab, !showingTabSwitcher {
            addNewReceiptButton
            
            if let tab = activeTab {
                TabSettleUpCard(
                    tabId: tab.id ?? "",
                    colorHex: tab.colorHex,
                    tabName: tab.name,
                    onSendSettlementCard: onSendSettlementCard,
                    onSendRequestCard: onSendRequestCard,
                    openInSafari: openInSafari
                )
            }
            segmentedPicker
            if selectedSegment == 0 {
                paymentsSection
            } else {
                membersList(for: tab)
                inviteMembersButton
            }
        } else if activeTab == nil && userTabs.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add up this chat's transactions with Loot Tabs! We'll do the math to settle up. When Loot is opened from this chat, receipts will be added to the selected tab.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                startNewTabButton
                orDivider
                Text("Join an existing tab by accepting a tab invite")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add up this chat's transactions with Loot Tabs!")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                startNewTabButton
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sortedUserTabs) { tab in
                            Button(action: {
                                onSelectTab?(tab)
                                showingTabSwitcher = false
                            }) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color(hex: tab.colorHex ?? TabColorOptions.defaultHex))
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.name)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(tab.members.count == 1 ? "1 member" : "\(tab.members.count) members")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 8) {
                                        ForEach(Array(tab.members.enumerated()), id: \.offset) { index, member in
                                            ColoredCircleBadge(
                                                    text: BadgeColors.initials(from: member.displayName, fallback: index),
                                                    color: BadgeColors.color(for: index)
                                                )
                                        }
                                    }
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reusable Sub-views
    private var addNewReceiptButton: some View {
        Button(action: {
            showingAddReceiptPanel = true
            onRequestCollapse()
        }) {
            HStack(spacing: 8) {
                Text("Add New Receipt")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
    
    private var startNewTabButton: some View {
        Button(action: { onStartTab?() }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                Text("Start a New Tab")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var inviteMembersButton: some View {
        Button(action: { onInviteMembers?() }) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 16))
                Text("Invite Members")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Segmented Picker

    private var segmentedPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Payments", "Members"].enumerated()), id: \.offset) { index, title in
                Button(action: { selectedSegment = index }) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selectedSegment == index ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedSegment == index ? Color.blue : Color.clear)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Payments Section

    private enum TabEvent: Identifiable {
        case receipt(TabReceipt)
        case settlement(Settlement)

        var id: String {
            switch self {
            case .receipt(let r): return "r-\(r.id ?? UUID().uuidString)"
            case .settlement(let s): return "s-\(s.id ?? UUID().uuidString)"
            }
        }
        var date: Date? {
            switch self {
            case .receipt(let r): return r.createdAt?.dateValue()
            case .settlement(let s): return s.createdAt?.dateValue()
            }
        }
    }

    private var sortedEvents: [TabEvent] {
        let r = receipts.map { TabEvent.receipt($0) }
        let s = settlements.map { TabEvent.settlement($0) }
        return (r + s).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func memberName(_ memberId: String) -> String {
        let myId = KeychainHelper.getOrCreateUserId()
        if memberId == myId { return "You" }
        return activeTab?.members.first(where: { $0.memberId == memberId })?.displayName ?? memberId
    }

    private func formatEventDate(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return f.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }

    @ViewBuilder
    private var paymentsSection: some View {

        if paymentsLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 24)
        } else if sortedEvents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No activity yet")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text("Upload or scan a receipt to add it to this tab")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(sortedEvents.enumerated()), id: \.element.id) { idx, event in
                    switch event {
                    case .receipt(let r): receiptEventRow(r)
                    case .settlement(let s): settlementEventRow(s)
                    }
                    if idx < sortedEvents.count - 1 {
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(14)
        }
    }

    @ViewBuilder
    private func receiptEventRow(_ receipt: TabReceipt) -> some View {
        Button (action: { onPreviewSplits?(receipt) }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 17))
                    .foregroundColor(.secondary)
                    .frame(width: 22)
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.title.isEmpty ? "Receipt" : receipt.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Text("Paid by \(memberName(receipt.payerMemberId))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ReceiptDisplay.money(receipt.totalCents))
                        .font(.system(size: 15, weight: .semibold))
                    Text(formatEventDate(receipt.createdAt?.dateValue()))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settlementEventRow(_ settlement: Settlement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(.green)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(memberName(settlement.fromMemberId))
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(memberName(settlement.toMemberId))
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                if let note = settlement.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ReceiptDisplay.money(settlement.amountCents))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                Text(formatEventDate(settlement.createdAt?.dateValue()))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }

    private func loadPayments() async {
        guard let tabId = activeTab?.id else {
            receipts = []; settlements = []
            return
        }
        paymentsLoading = true
        do {
            async let r = TabService.shared.fetchReceipts(forTab: tabId)
            async let s = TabService.shared.fetchSettlements(forTab: tabId)
            receipts = try await r
            settlements = try await s
        } catch {
            print("[LootTabView] loadPayments failed: \(error)")
        }
        paymentsLoading = false
    }

    // MARK: - Members List

    private func membersList(for tab: LootTab) -> some View {
        let currentUserId = KeychainHelper.getOrCreateUserId()

        return VStack(spacing: 0) {
            ForEach(Array(tab.members.enumerated()), id: \.element.id) { index, member in
                HStack {
                    Text(member.displayName + (member.memberId == currentUserId ? " (You)" : ""))
                        .font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text(ReceiptDisplay.money(member.balanceCents))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(member.balanceCents > 0 ? .green : member.balanceCents < 0 ? .red : .secondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)

                if index < tab.members.count - 1 {
                    Divider()
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)
            Text("OR")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)
        }
    }
}
