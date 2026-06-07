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
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var messageReceiptVM: MessageReceiptViewModel
    @ObservedObject var tabContextVM: TabContextViewModel

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
    var onApplePayHandoff: ((String, String, Int, String?) -> Void)? = nil
    var onSendRequestCard: ((String, String, Int, String?, RequestCardMetadata?) -> Void)? = nil
    var openInSafari: ((URL) -> Void)? = nil
    var pendingPayRequest: PendingPayRequest? = nil
    var onConsumePendingPayRequest: (() -> Void)? = nil
    var paymentsRefreshNonce: Int = 0
    let onRequestCollapse: () -> Void
    
    @AppStorage(DefaultsKeys.myDisplayName) private var myDisplayName: String = ""
    @State private var showingTabSwitcher: Bool = false
    @State private var showingAddReceiptPanel: Bool = false
    @State private var showingTabSettings: Bool = false
    @State private var selectedSegment: Int = 0
    @State private var receipts: [TabReceipt] = []
    @State private var settlements: [Settlement] = []
    @State private var paymentsLoading: Bool = false
    @State private var memberSheetTarget: TabMember? = nil

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
                    // Apple Pay reminder takes over compact when the sender
                    // just confirmed an Apple Cash handoff. Centered vertically
                    // so it clears the account-initials overlay at top-right
                    // and the tabBar at the bottom. Expanded paths run the
                    // regular flow so the user can still navigate the app.
                    if let info = messageReceiptVM.pendingApplePayInfo, !isExpanded {
                        Spacer(minLength: 0)
                        applePayPendingCompactCard(info: info)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 0.25).delay(0.35)),
                                removal: .opacity.animation(.easeOut(duration: 0.15))
                            ))
                        Spacer(minLength: 0)
                    } else {
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
                    .overlay(
                        Circle().stroke(
                            activeTab != nil ? Color.white.opacity(0.6) : Color(UIColor.separator),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 16)
        }
        .sheet(isPresented: $showingTabSettings) {
            if let tab = activeTab {
                TabSettingsView(
                    tab: tab,
                    coordinator: coordinator,
                    tabContextVM: tabContextVM,
                    onSave: { updatedTab in onTabUpdated?(updatedTab) },
                    onLeft: { onTabLeft?() },
                    onDeleted: { onTabDeleted?() }
                )
            }
        }
        .sheet(item: $memberSheetTarget) { member in
            if let tab = activeTab {
                MemberSettleUpSheet(
                    tabId: tab.id ?? "",
                    tabName: tab.name,
                    colorHex: tab.colorHex,
                    memberId: member.memberId,
                    onSendSettlementCard: onSendSettlementCard,
                    onApplePayHandoff: onApplePayHandoff,
                    onSendRequestCard: onSendRequestCard,
                    openInSafari: openInSafari,
                    onRequestCollapse: onRequestCollapse,
                    onApplePayPending: { toName, amountCents, colorHex in
                        messageReceiptVM.pendingApplePayInfo = PendingApplePayInfo(
                            toName: toName,
                            amountCents: amountCents,
                            tabColorHex: colorHex
                        )
                    }
                )
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            if !newValue { showingAddReceiptPanel = false }
            if newValue, activeTab?.id != nil {
                Task { await loadPayments() }
            }
        }
        .task(id: "\(activeTab?.id ?? "none")-\(paymentsRefreshNonce)") {
            await loadPayments()
        }
    }

    // MARK: - Apple Pay Reminder (compact)

    private var applePayInGroupChatSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    @ViewBuilder
    private func applePayPendingCompactCard(info: PendingApplePayInfo) -> some View {
        let bg: Color = {
            if let hex = info.tabColorHex { return Color(hex: hex) }
            return Color(.secondarySystemBackground)
        }()
        let fg: Color = info.tabColorHex != nil ? .white : .primary
        let sub: Color = info.tabColorHex != nil ? .white.opacity(0.75) : .secondary

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(fg)
                    Text("Sending \(ReceiptDisplay.money(info.amountCents)) to \(info.toName)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Text(applePayInGroupChatSupported
                     ? "Tap the + button (top-left of the chat input) to open Apple Cash and send."
                     : "Open a 1:1 chat with \(info.toName) to send via Apple Cash.")
                    .font(.system(size: 12))
                    .foregroundColor(sub)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    messageReceiptVM.pendingApplePayInfo = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(sub)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
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

            HStack(spacing: 12) {
                captureTile(
                    icon: "camera.viewfinder",
                    title: "Scan Receipt",
                    color: Color(hex: "005377"),
                    action: onScan
                )

                captureTile(
                    icon: "square.and.pencil",
                    title: "Enter Total",
                    color: Color(hex: "06A77D"),
                    action: onFill
                )
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func captureTile(
        icon: String,
        title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        let onColored = isColoredCompact
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(onColored ? Color.white : color)
                    Image(systemName: icon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(onColored ? resolvedHeaderColor : .white)
                }
                .frame(width: 54, height: 54)
                .shadow(
                    color: onColored ? Color.black.opacity(0.12) : color.opacity(0.35),
                    radius: 7, y: 4
                )

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(onColored ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                onColored ? Color.white.opacity(0.16) : Color(UIColor.secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        onColored ? Color.white.opacity(0.22) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PressableTileStyle())
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
                            Button(action: { showingTabSettings = true }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                            Button(action: { onClearTab?() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.5))
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
                    onApplePayHandoff: onApplePayHandoff,
                    onSendRequestCard: onSendRequestCard,
                    openInSafari: openInSafari,
                    pendingPayRequest: pendingPayRequest,
                    onConsumePendingPayRequest: onConsumePendingPayRequest,
                    onRequestCollapse: onRequestCollapse,
                    onApplePayPending: { toName, amountCents, colorHex in
                        messageReceiptVM.pendingApplePayInfo = PendingApplePayInfo(
                            toName: toName,
                            amountCents: amountCents,
                            tabColorHex: colorHex
                        )
                    },
                    refreshNonce: paymentsRefreshNonce
                )
            }
            segmentedPicker
            if selectedSegment == 0 {
                paymentsSection
            } else {
                membersSection(for: tab)
            }
        } else if activeTab == nil && userTabs.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add up this chat's transactions — we'll do the math to get even.")
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
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        let activeMembers = tab.members.filter(\.isActive)
                                        Text(activeMembers.count == 1 ? "1 member" : "\(activeMembers.count) members")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .layoutPriority(1)
                                    Spacer(minLength: 8)
                                    // Tabs with many members previously stacked every
                                    // ColoredCircleBadge in an unbounded HStack — which
                                    // squeezed the tab name's VStack so narrow that the
                                    // name wrapped onto multiple lines, ballooning the
                                    // row vertically. Cap visible badges to a few,
                                    // overlap them slightly, and tack on a "+N" chip
                                    // for the remainder. Layout stays a fixed width
                                    // regardless of member count.
                                    membersStrip(for: tab)
                                        .layoutPriority(0)
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

    /// Renders the trailing badge strip for a tab in the tabs-list entry.
    /// Shows up to `visibleLimit` member badges (overlapped slightly with
    /// negative spacing) and appends a "+N" chip when more members exist.
    /// Cap + overlap keeps the strip a bounded width regardless of how
    /// many people are in the tab, so the tab name's VStack always has
    /// room and never wraps onto a second line.
    @ViewBuilder
    private func membersStrip(for tab: LootTab) -> some View {
        let activeMembers = tab.members.filter(\.isActive)
        let visibleLimit = 4
        let visible = Array(activeMembers.prefix(visibleLimit).enumerated())
        let overflow = max(0, activeMembers.count - visibleLimit)
        HStack(spacing: -8) {
            ForEach(visible, id: \.offset) { index, member in
                ColoredCircleBadge(
                    text: BadgeColors.initials(from: member.displayName, fallback: index),
                    color: BadgeColors.color(for: index)
                )
                .overlay(
                    Circle()
                        .stroke(Color(UIColor.secondarySystemBackground), lineWidth: 2)
                )
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary))
                    .overlay(
                        Circle()
                            .stroke(Color(UIColor.secondarySystemBackground), lineWidth: 2)
                    )
            }
        }
        .fixedSize()
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
        // Prefer live name via uid → DisplayNameCache (kept current by
        // SplitsSummaryView's Firestore fetch, AccountView edits, and
        // TabService fetch/listen). Falls back to the tab.member's
        // frozen displayName, and lastly the raw memberId. Keeping all
        // three rendering paths on the same precedence is what stops
        // the bubble / summary / list from disagreeing.
        if let m = activeTab?.members.first(where: { $0.memberId == memberId }) {
            if let uid = m.userId, !uid.isEmpty,
               let cached = DisplayNameCache.lookup(uid) {
                return cached
            }
            let frozen = m.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !frozen.isEmpty { return frozen }
        }
        return memberId
    }

    private func payerLabel(for receipt: TabReceipt) -> String {
        let myId = KeychainHelper.getOrCreateUserId()
        if receipt.payerMemberId == myId { return "You" }

        // Live name via tab member → DisplayNameCache, identical
        // precedence to memberName() above. The frozen receipt
        // .payerDisplayName is only used when we have no tab-member
        // entry to map memberId → uid (e.g. a former member).
        if let m = activeTab?.members.first(where: { $0.memberId == receipt.payerMemberId }) {
            if let uid = m.userId, !uid.isEmpty,
               let cached = DisplayNameCache.lookup(uid) {
                return cached
            }
            let frozen = m.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !frozen.isEmpty { return frozen }
        }
        if let name = receipt.payerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return receipt.payerMemberId
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
    private func membersSection(for tab: LootTab) -> some View {
        if paymentsLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 24)
        } else {
            membersList(for: tab)
            inviteMembersButton
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
                    Text("Paid by \(payerLabel(for: receipt))")
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
            .contentShape(Rectangle())
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
        // Past members (left the tab) stay in `tab.members` for historical
        // balance lookups but should not appear in the live members list.
        let activeMembers = tab.members.filter(\.isActive)

        return VStack(spacing: 0) {
            ForEach(Array(activeMembers.enumerated()), id: \.element.id) { index, member in
                // Color the badge by the member's full-list index (incl.
                // inactive members) so it stays stable for a given member
                // even if someone else leaves and the active-list order
                // shifts. Matches MemberSettleUpSheet and TabSettleUpCard,
                // which both index against tab.members.
                let badgeIdx = tab.members.firstIndex(where: { $0.memberId == member.memberId }) ?? index
                Button {
                    memberSheetTarget = member
                } label: {
                    HStack(spacing: 10) {
                        ColoredCircleBadge(
                            text: BadgeColors.initials(from: member.displayName, fallback: badgeIdx),
                            color: BadgeColors.color(for: badgeIdx)
                        )
                        Text(member.displayName + (member.memberId == currentUserId ? " (You)" : ""))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(ReceiptDisplay.money(member.balanceCents))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(member.balanceCents > 0 ? .green : member.balanceCents < 0 ? .red : .secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < activeMembers.count - 1 {
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

private struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
