//
//  GuestListView.swift
//  Loot
//
//  Shared guest list rendered below the split panels (equal, custom, by-items).
//  Stays as `extension ConfirmationView` because the per-row name TextField
//  binds @FocusState (`guestNameFocusedID`) which can only live on a View,
//  not on `SplitEditorViewModel`. Reads VM state via `splitEditorVM.X`,
//  mutations go through `splitEditorVM.method(...)`.
//
import SwiftUI

extension ConfirmationView {

    // MARK: - Shared guest list (used by all split modes)
    func guestList() -> some View {
        VStack(spacing: 8) {
            // "Paid by [Name]" payer selector
            HStack(spacing: 4) {
                Text("Paid by")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                Menu {
                    ForEach(splitEditorVM.activeGuests) { guest in
                        Button {
                            splitEditorVM.payerID = guest.id
                            splitEditorVM.draftPayerID = guest.id
                        } label: {
                            HStack {
                                Text(splitEditorVM.displayName(for: guest, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: guest.id)))
                                if guest.id == splitEditorVM.payerID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(splitEditorVM.payerDisplayName())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            ScrollView {
                ForEach(0..<splitEditorVM.activeCount, id: \.self) { i in
                    let guest = splitEditorVM.activeGuests[i]
                    let gid = guest.id
                    let isSenderRow = guest.isMe(localUserId: splitEditorVM.localUserId)
                    let selectionDisabled = splitEditorVM.claimMode && splitEditorVM.mode == .byItems && !isSenderRow
                    let isSelected: Bool = splitEditorVM.mode == .byItems
                    ? gid == splitEditorVM.byItemSelectedGuestID && !selectionDisabled
                    : i == splitEditorVM.guestSelectedIndex

                    HStack(spacing: 8) {
                        // Badge – tap to select guest (disabled for non-sender
                        // rows when claimMode is on; the sender can only
                        // claim items for themselves).
                        ColoredCircleBadge(
                            text: BadgeColors.initials(
                                from: splitEditorVM.displayName(for: guest, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: gid)),
                                fallback: splitEditorVM.allIndex(for: gid) ?? i
                            ),
                            color: splitEditorVM.colorForActiveIdx(i)
                        )
                        .opacity(selectionDisabled ? 0.5 : 1)
                        .onTapGesture {
                            guard !selectionDisabled else { return }
                            if splitEditorVM.mode == .byItems { splitEditorVM.byItemSelectedGuestID = gid }
                            else { splitEditorVM.guestSelectedIndex = i }
                        }

                        // Name – tap to edit inline (disabled for tab members)
                        let isMe = guest.isMe(localUserId: splitEditorVM.localUserId)
                        let isTabMember = tabContextVM.activeTab != nil && guest.userId != nil && !guest.userId!.isEmpty
                        let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if splitEditorVM.editingGuestNameID == gid && !isMe && !isTabMember {
                            TextField(
                                "Guest name",
                                text: Binding(
                                    get: {
                                        splitEditorVM.guests.first(where: { $0.id == gid })?.displayName ?? ""
                                    },
                                    set: { newValue in
                                        if let idx = splitEditorVM.guests.firstIndex(where: { $0.id == gid }) {
                                            splitEditorVM.guests[idx].displayName = newValue
                                            splitEditorVM.draftGuests = splitEditorVM.guests
                                        }
                                    }
                                )
                            )
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .focused($guestNameFocusedID, equals: gid)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit {
                                splitEditorVM.editingGuestNameID = nil
                            }
                        } else {
                            let isUnnamed = trimmed.isEmpty && !isMe
                            Text(splitEditorVM.displayName(for: guest, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: gid)))
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isUnnamed ? .secondary : .primary)
                                .onTapGesture {
                                    if !isMe && !isTabMember {
                                        splitEditorVM.editingGuestNameID = gid
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            guestNameFocusedID = gid
                                        }
                                    }
                                }
                        }

                        Spacer()

                        // Right side: amount (byItems shows running total; other modes show editable amount)
                        if splitEditorVM.mode == .byItems {
                            let guestCents = splitEditorVM.byItemsGuestCents(for: gid)
                            // In claim mode: only show the sender's amount.
                            // Other guests' running totals stay hidden in
                            // compose — recipients claim their own items in
                            // chat, so showing $0.00 for everyone else is noise.
                            let shouldShowAmount = !splitEditorVM.claimMode || isSenderRow
                            if shouldShowAmount {
                                Text(ReceiptDisplay.money(guestCents))
                                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(guestCents > 0 ? .primary : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color(.tertiarySystemFill) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Text(ReceiptDisplay.money(splitEditorVM.guestAmountsCents.indices.contains(i) ? splitEditorVM.guestAmountsCents[i] : 0))
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(splitEditorVM.mode != .byItems ? Color(.tertiarySystemFill) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if splitEditorVM.mode != .byItems {
                                        splitEditorVM.startEditingAmount(for: i)
                                        isAmountFieldFocused = true
                                    }
                                }
                        }

                        // Remove/exclude button (hidden when only one included guest remains)
                        if splitEditorVM.activeCount > 1 {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    splitEditorVM.removeGuestInline(guestId: gid, totalCents: totalCents)
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.red.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Dismiss any open name edit when tapping another row
                        if splitEditorVM.editingGuestNameID != nil && splitEditorVM.editingGuestNameID != gid {
                            splitEditorVM.editingGuestNameID = nil
                            guestNameFocusedID = nil
                        }
                        guard !selectionDisabled else { return }
                        if splitEditorVM.mode == .byItems { splitEditorVM.byItemSelectedGuestID = gid }
                        else { splitEditorVM.guestSelectedIndex = i }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isSelected && splitEditorVM.mode != .equally ? Color(.secondarySystemBackground) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxHeight: 230)
            .defaultScrollAnchor(.bottom)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Custom mode remaining
            if splitEditorVM.mode == .custom {
                let remaining = max(0, totalCents - splitEditorVM.guestAmountsCents.reduce(0, +))
                HStack {
                    Text("Remaining")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(ReceiptDisplay.money(remaining))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(remaining == 0 ? .secondary : .orange)
                }
                .padding(.top, 4)
            }

            // Add guest button (hidden when tab is active — guests come from tab members)
            if tabContextVM.activeTab == nil {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        splitEditorVM.addGuestInline(totalCents: totalCents)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                        Text("Add Guest")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            // Excluded guests section (only guests with UIDs)
            let excludedWithUid = splitEditorVM.guests.filter { !splitEditorVM.includedIDs.contains($0.id) && !(($0.userId ?? "").isEmpty) }
            if !excludedWithUid.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not Included")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    ForEach(excludedWithUid) { guest in
                        HStack(spacing: 8) {
                            ColoredCircleBadge(
                                text: BadgeColors.initials(from: splitEditorVM.displayName(for: guest, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: guest.id)), fallback: splitEditorVM.allIndex(for: guest.id) ?? 0),
                                color: splitEditorVM.colorForGuestId(guest.id)
                            )
                            Text(splitEditorVM.displayName(for: guest, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: guest.id)))
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    splitEditorVM.reIncludeGuest(guestId: guest.id, totalCents: totalCents)
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .onChange(of: guestNameFocusedID) { _, newValue in
            if newValue == nil {
                splitEditorVM.editingGuestNameID = nil
            }
        }
    }
}
