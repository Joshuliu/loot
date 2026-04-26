//
//  TabSettingsView.swift
//  Loot
//

import SwiftUI

struct TabSettingsView: View {
    let tab: LootTab
    @ObservedObject var uiModel: LootUIModel
    let onSave: (LootTab) -> Void
    var onLeft: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @State private var name: String
    @State private var selectedColor: String
    @State private var members: [TabMember]
    @State private var newGuestName: String = ""
    @State private var showingAddGuest: Bool = false
    @State private var isSaving: Bool = false
    @State private var isLeaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var showingLeaveConfirm: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var saveError: String? = nil

    @Environment(\.dismiss) private var dismiss

    private let myId = KeychainHelper.getOrCreateUserId()

    init(tab: LootTab,
         uiModel: LootUIModel,
         onSave: @escaping (LootTab) -> Void,
         onLeft: (() -> Void)? = nil,
         onDeleted: (() -> Void)? = nil) {
        self.tab = tab
        self.uiModel = uiModel
        self.onSave = onSave
        self.onLeft = onLeft
        self.onDeleted = onDeleted
        self._name = State(initialValue: tab.name)
        self._selectedColor = State(initialValue: tab.colorHex ?? TabColorOptions.defaultHex)
        self._members = State(initialValue: tab.members)
    }

    /// Merges live tab members from `uiModel.activeTab` into the local working
    /// list. Preserves any locally-added (not-yet-saved) guests — those are
    /// members with `userId == nil` whose memberId isn't in the remote list.
    private func mergeLiveMembers() {
        guard let liveTab = uiModel.activeTab, liveTab.id == tab.id else { return }
        let remoteIds = Set(liveTab.members.map(\.memberId))
        let localOnly = members.filter { $0.userId == nil && !remoteIds.contains($0.memberId) }
        members = liveTab.members + localOnly
    }

    private var myBalance: Int {
        members.first(where: { $0.memberId == myId })?.balanceCents ?? 0
    }

    private var isOnlyActiveMember: Bool {
        members.filter({ $0.isActive }).count == 1 &&
        members.first(where: { $0.isActive })?.memberId == myId
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Name
                Section("Tab Name") {
                    TextField("Tab name", text: $name)
                }

                // MARK: Color
                Section("Color") {
                    HStack(spacing: 16) {
                        ForEach(TabColorOptions.all, id: \.self) { hex in
                            Button {
                                selectedColor = hex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 34, height: 34)
                                    if selectedColor == hex {
                                        Circle()
                                            .stroke(Color(hex: hex), lineWidth: 2)
                                            .frame(width: 42, height: 42)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                // MARK: Members
                Section {
                    // Past members (left the tab) are preserved in `members`
                    // for historical balance/name lookups but should not show
                    // up in the live list.
                    let activeMembers = members.filter(\.isActive)
                    ForEach(Array(activeMembers.enumerated()), id: \.element.id) { index, member in
                        HStack(spacing: 12) {
                            ColoredCircleBadge(
                                text: BadgeColors.initials(from: member.displayName, fallback: index),
                                color: BadgeColors.color(for: index)
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName + (member.memberId == myId ? " (You)" : ""))
                                    .font(.system(size: 15, weight: .medium))
                                Text(member.userId != nil ? "Loot member" : "Guest")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if showingAddGuest {
                        HStack(spacing: 8) {
                            TextField("Guest name", text: $newGuestName)
                                .onSubmit { addGuest() }
                            Button("Add") { addGuest() }
                                .disabled(newGuestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } header: {
                    HStack {
                        Text("Members")
                        Spacer()
                        Button {
                            withAnimation { showingAddGuest.toggle() }
                            newGuestName = ""
                        } label: {
                            Image(systemName: showingAddGuest ? "xmark" : "person.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                } footer: {
                    Text("Loot members can only be removed by leaving the tab themselves.")
                        .font(.system(size: 12))
                }

                // MARK: Error
                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                            .font(.system(size: 13))
                    }
                }

                // MARK: Leave / Delete Tab
                Section {
                    if myBalance == 0 {
                        if isOnlyActiveMember {
                            if isDeleting {
                                HStack {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Deleting…")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 15))
                                }
                            } else {
                                Button("Delete Tab", role: .destructive) {
                                    showingDeleteConfirm = true
                                }
                            }
                        } else {
                            if isLeaving {
                                HStack {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Leaving…")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 15))
                                }
                            } else {
                                Button("Leave Tab", role: .destructive) {
                                    showingLeaveConfirm = true
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Must \(myBalance < 0 ? "get paid" : "pay back") to leave")
                                .font(.system(size: 15, weight: .medium))
                            Text("Your balance is \(ReceiptDisplay.money(abs(myBalance)))\(myBalance < 0 ? " owed" : " to receive"). Settle up first.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    if myBalance == 0 {
                        if isOnlyActiveMember {
                            Text("Deleting the tab removes it permanently. All receipts and payment history will be lost.")
                        } else {
                            Text("Leaving removes you from active membership. Your past receipts and payments remain intact for other members.")
                        }
                    }
                }
            }
            .navigationTitle("Tab Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Leave \"\(tab.name)\"?", isPresented: $showingLeaveConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Leave", role: .destructive) { performLeave() }
            } message: {
                Text("You'll be removed as an active member. Your historical receipts and payments are preserved for everyone.")
            }
            .alert("Delete \"\(tab.name)\"?", isPresented: $showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { performDelete() }
            } message: {
                Text("This will permanently delete the tab and all its history. This cannot be undone.")
            }
            .onAppear { mergeLiveMembers() }
            .onChange(of: liveTabMembersFingerprint) { _, _ in mergeLiveMembers() }
        }
    }

    /// Compact identity string for `uiModel.activeTab.members` so SwiftUI's
    /// `.onChange(of:)` has a simple value-typed expression to type-check.
    /// `uiModel.activeTab?.members` would otherwise blow the type-checker
    /// budget when this Form body is already large.
    private var liveTabMembersFingerprint: String {
        guard let tab = uiModel.activeTab, tab.id == self.tab.id else { return "" }
        return tab.members
            .map { "\($0.memberId):\($0.displayName):\($0.isActive ? 1 : 0)" }
            .joined(separator: "|")
    }

    // MARK: - Actions

    private func performLeave() {
        guard let tabId = tab.id else { return }
        isLeaving = true
        saveError = nil
        Task {
            do {
                try await TabService.shared.leaveTab(tabId: tabId)
                await MainActor.run {
                    onLeft?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saveError = "Failed to leave: \(error.localizedDescription)"
                    isLeaving = false
                }
            }
        }
    }

    private func performDelete() {
        guard let tabId = tab.id else { return }
        isDeleting = true
        saveError = nil
        Task {
            do {
                try await TabService.shared.deleteTab(tabId: tabId)
                await MainActor.run {
                    onDeleted?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saveError = "Failed to delete: \(error.localizedDescription)"
                    isDeleting = false
                }
            }
        }
    }

    private func addGuest() {
        let trimmed = newGuestName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newMember = TabMember(
            memberId: UUID().uuidString,
            userId: nil,
            displayName: trimmed,
            balanceCents: 0,
            isActive: true
        )
        members.append(newMember)
        newGuestName = ""
        showingAddGuest = false
    }

    private func save() {
        var updated = tab
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.colorHex = selectedColor
        updated.members = members
        updated.memberIds = members.map(\.memberId)

        isSaving = true
        saveError = nil

        Task {
            do {
                try await TabService.shared.updateTab(updated)
                await MainActor.run {
                    onSave(updated)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saveError = "Failed to save: \(error.localizedDescription)"
                    isSaving = false
                }
            }
        }
    }
}
