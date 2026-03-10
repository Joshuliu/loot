//
//  JoinTabView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct JoinTabView: View {
    @ObservedObject var uiModel: LootUIModel
    var isExpanded: Bool = true

    let onRequestExpand: () -> Void
    let onBack: () -> Void
    let onJoined: (LootTab) -> Void
    var onAccountTapped: (() -> Void)? = nil

    @AppStorage(DefaultsKeys.myDisplayName) private var myDisplayName: String = ""
    @State private var isLoading: Bool = false
    @State private var tab: LootTab? = nil
    @State private var errorMessage: String? = nil

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
            if isLoading {
                Spacer()
            } else if let tab {
                ZStack {
                    // Tab pill — left-center in compact, bottom-left in expanded
                    Button(action: { onRequestExpand() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .font(.system(size: 18))
                            Text(tab.name)
                                .font(.system(size: 24, weight: .semibold))
                                .scaleEffect(isExpanded ? 1.0 : 20.0 / 24.0, anchor: .leading)
                                .lineLimit(1)
                            if !isExpanded {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(isExpanded ? 0 : 0.15))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: isExpanded ? .bottomLeading : .leading)

                    // Account circle — right-center in compact, top-right in expanded
                    Button(action: { onAccountTapped?() }) {
                        Text(initials)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: tab.colorHex ?? TabColorOptions.defaultHex))
                            .frame(width: 38, height: 38)
                            .background(Color.white)
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
                .background(Color(hex: tab.colorHex ?? TabColorOptions.defaultHex))

                VStack(spacing: 0) {
                    Text("Loot Tab Invite")
                        .font(.system(size: 28, weight: .bold))
                        .scaleEffect(isExpanded ? 1.0 : 0.8, anchor: .center)
                        .padding(.top, isExpanded ? 16 : 0)
                        .padding(.bottom, isExpanded ? 16 : 6)

                    if isExpanded {
                        VStack(spacing: 0) {
                            if let creator = tab.members.first(where: { $0.memberId == tab.createdBy }) {
                                Text("Created by \(creator.displayName)")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }

                            Text("Add up this chat's transactions with Loot Tabs! We'll do the math to settle up. When Loot is opened from this chat, receipts will be added to this tab.")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 16)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    VStack(alignment: isExpanded ? .leading : .center, spacing: 8) {
                        Text("Members")
                            .font(.system(size: isExpanded ? 14 : 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if isExpanded {
                            ForEach(Array(tab.members.enumerated()), id: \.offset) { index, member in
                                HStack(spacing: 8) {
                                    ColoredCircleBadge(
                                        text: BadgeColors.initials(from: member.displayName, fallback: index),
                                        color: BadgeColors.color(for: index)
                                    )
                                    Text(member.displayName)
                                        .font(.system(size: 16))
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                ForEach(Array(tab.members.enumerated()), id: \.offset) { index, member in
                                    ColoredCircleBadge(
                                            text: BadgeColors.initials(from: member.displayName, fallback: index),
                                            color: BadgeColors.color(for: index)
                                        )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: isExpanded ? .infinity : nil, alignment: isExpanded ? .leading : .center)
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Spacer()

                    HStack(spacing: 12) {
                        Button {
                            onBack()
                        } label: {
                            Text("Decline")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, isExpanded ? 12 : 8)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            joinTab(tab)
                        } label: {
                            Text("Join")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, isExpanded ? 12 : 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, isExpanded ? 24 : 16)
                
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load tab")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isExpanded)
        .task {
            onRequestExpand()
            await loadTab()
        }
    }

    private func loadTab() async {
        guard let tabId = uiModel.pendingTabInviteId else {
            errorMessage = "No tab invite ID"
            return
        }
        isLoading = true
        do {
            if let fetched = try await TabService.shared.fetchTab(id: tabId) {
                // Already a member — just select the tab and go back
                let myId = KeychainHelper.getOrCreateUserId()
                if fetched.memberIds.contains(myId) {
                    uiModel.activeTab = fetched
                    uiModel.pendingTabInviteId = nil
                    onJoined(fetched)
                    isLoading = false
                    return
                }
                tab = fetched
            } else {
                // Stub: create a placeholder since fetchTab returns nil
                let creator = TabMember(
                    memberId: UUID().uuidString,
                    userId: nil,
                    displayName: "Someone",
                    balanceCents: 0,
                    isActive: true
                )
                var placeholder = LootTab(
                    name: "Shared Tab",
                    createdBy: creator.memberId,
                    status: .active,
                    members: [creator],
                    memberIds: [creator.memberId],
                    receiptCount: 0
                )
                placeholder.id = tabId
                tab = placeholder
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func joinTab(_ tab: LootTab) {
        Task { @MainActor in
            do {
                let joined = try await TabService.shared.joinTab(
                    tabId: tab.id ?? "",
                    conversationKey: uiModel.conversationKey ?? ""
                )
                uiModel.activeTab = joined
                onJoined(joined)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
