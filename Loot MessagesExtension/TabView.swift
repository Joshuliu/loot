//
//  TabView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import SwiftUI

struct LootTabView: View {
    @Binding var tabName: String

    var onUpload: () -> Void
    var onScan: () -> Void
    var onFill: () -> Void

    // Tab-related props
    var activeTab: LootTab? = nil
    var userTabs: [LootTab] = []
    var isExpanded: Bool = false
    var onStartTab: (() -> Void)? = nil
    var onSelectTab: ((LootTab) -> Void)? = nil
    var onTabNameTapped: (() -> Void)? = nil
    var onClearTab: (() -> Void)? = nil
    var onInviteMembers: (() -> Void)? = nil
    var onAccountTapped: (() -> Void)? = nil

    @AppStorage(DefaultsKeys.myDisplayName) private var myDisplayName: String = ""
    @State private var showingTabSwitcher: Bool = false
    @State private var selectedSegment: Int = 0

    private var resolvedHeaderColor: Color {
        Color(hex: activeTab?.colorHex ?? TabColorOptions.defaultHex)
    }

    private var isColoredCompact: Bool {
        activeTab != nil && !isExpanded
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
                if !isExpanded {
                    compactInnerContent
                        .padding(.top, 20)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.25).delay(0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        ))

                    Spacer()
                }
                tabBar
            }
            .background(
                activeTab != nil
                    ? resolvedHeaderColor
                    : Color.clear
            )

            // Bottom section: expanded content slides up from below
            if isExpanded {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        expandedTabContent
                    }
                    .padding(.horizontal, 16)

                    Spacer()
                }
                .padding(.top, 12)
                .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isExpanded)
    }

    // MARK: - Tab Bar (pill + circle, animates between compact/expanded layout)

    var tabBar: some View {
        ZStack {
            // Tab pill — left-center in compact, bottom-left in expanded
            Button(action: { onTabNameTapped?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 18))
                    Text((!showingTabSwitcher ? activeTab?.name : nil) ?? "Loot Tabs")
                        .font(.system(size: 24, weight: .semibold))
                        .scaleEffect(isExpanded ? 1.0 : 20.0 / 24.0, anchor: .leading)
                        .lineLimit(1)
                    if !isExpanded {
                        if activeTab != nil {
                                Button(action: { onClearTab?() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(activeTab != nil ? .white.opacity(0.5) : .secondary)
                                }
                                .buttonStyle(.plain)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(activeTab != nil ? .white.opacity(0.5) : .secondary)
                        }
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

            // Account circle — right-center in compact, top-right in expanded
            Button(action: { onAccountTapped?() }) {
                Text(initials)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(activeTab != nil ? resolvedHeaderColor : .white)
                    .frame(width: 38, height: 38)
                    .background(activeTab != nil ? Color.white : Color.black)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isExpanded ? .topTrailing : .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: isExpanded ? 120 : 66)
        .frame(maxWidth: .infinity)
        .background(
            activeTab != nil
                ? resolvedHeaderColor
                : Color.clear
        )
    }

    // MARK: - Compact Inner Content (title + buttons + labels)

    private var compactInnerContent: some View {
        VStack(spacing: 20) {
            Text(activeTab != nil ? "Add Receipt to Tab" : "Split New Receipt")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isColoredCompact ? .white : .primary)
                .padding(.horizontal, 16)

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

                    Text("Fill In")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isColoredCompact ? .white.opacity(0.85) : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Expanded Tab Content

    @ViewBuilder
    private var expandedTabContent: some View {
        if let tab = activeTab, !showingTabSwitcher {
            balanceSummaryCard(for: tab)
            segmentedPicker
            if selectedSegment == 0 {
                paymentsEmptyState
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
                Text("Add up this chat's transactions with Loot Tabs! We'll do the math to settle up. When Loot is opened from this chat, receipts will be added to the selected tab.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                startNewTabButton
                orDivider
                Text("Join an existing tab by accepting a tab invite")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                orDivider
                Text("Select another tab for this chat to add a new receipt to it. ")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(userTabs) { tab in
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

    // MARK: - Balance Summary Card

    private func balanceSummaryCard(for tab: LootTab) -> some View {
        let currentUserId = KeychainHelper.getOrCreateUserId()
        let balanceCents = tab.members.first(where: { $0.memberId == currentUserId })?.balanceCents ?? 0

        let balanceText: String
        let balanceColor: Color

        if balanceCents > 0 {
            balanceText = "You're owed $\(String(format: "%.2f", Double(balanceCents) / 100.0))"
            balanceColor = .green
        } else if balanceCents < 0 {
            balanceText = "You owe $\(String(format: "%.2f", Double(abs(balanceCents)) / 100.0))"
            balanceColor = .red
        } else {
            balanceText = "$0.00"
            balanceColor = .secondary
        }

        return VStack(spacing: 4) {
            Text(balanceText)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(balanceColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
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

    // MARK: - Payments Empty State

    private var paymentsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No receipts yet")
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
                    Text(formatCents(member.balanceCents))
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

    // MARK: - Helpers

    private func formatCents(_ cents: Int) -> String {
        let dollars = Double(abs(cents)) / 100.0
        let formatted = String(format: "$%.2f", dollars)
        return cents < 0 ? "-\(formatted)" : formatted
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
