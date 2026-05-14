//
//  SplitView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//
//  Split-editor panel views (donut, by-items, toolbar, mode picker, amount
//  editor overlay, navigation toolbar). Math/state/mutation logic lives on
//  `SplitEditorViewModel`. The shared guest list lives in GuestListView.swift;
//  donut and slider components live under Components/.
//
import SwiftUI

// MARK: - ConfirmationView Split Panel Extension
//
// View methods stay on ConfirmationView (rather than `extension
// SplitEditorViewModel`) because they wire @FocusState bindings directly into
// TextField/`.focused(...)` modifiers — a pattern that only compiles inside a
// View. Methods read state via `splitEditorVM.X` and call mutations via
// `splitEditorVM.method(...)`.

extension ConfirmationView {

    // MARK: - Split mode button (for extension use)
    func splitModeButton(_ m: SplitDraft.Mode) -> some View {
        let selected = (m == splitEditorVM.mode)
        return Button {
            splitEditorVM.selectMode(m, totalCents: totalCents)
            splitEditorVM.confirmed = false
        } label: {
            Text(m.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.blue : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Guest donut view (used for equally + custom)
    func byGuestPanel(interactive: Bool) -> some View {
        let selectedCents = splitEditorVM.guestAmountsCents.indices.contains(splitEditorVM.guestSelectedIndex)
        ? splitEditorVM.guestAmountsCents[splitEditorVM.guestSelectedIndex]
        : 0

        let parts = splitEditorVM.moneyParts(selectedCents)

        let g = splitEditorVM.activeGuests.indices.contains(splitEditorVM.guestSelectedIndex) ? splitEditorVM.activeGuests[splitEditorVM.guestSelectedIndex] : nil
        let centerName = g.map { splitEditorVM.displayName(for: $0, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: $0.id)) } ?? "Guest"

        return VStack(alignment: .leading, spacing: 0) {
            splitPanelToolbar()

            Spacer(minLength: 0)

            DonutChart(
                activeCount: splitEditorVM.activeCount,
                totalCents: totalCents,
                interactive: interactive,
                isEqualMode: splitEditorVM.mode == .equally,
                selectedIndex: $splitEditorVM.guestSelectedIndex,
                guestAmountsCents: $splitEditorVM.guestAmountsCents,
                fineTunerScrollTarget: $splitEditorVM.fineTunerScrollTarget,
                centerName: centerName,
                centerMoneyParts: parts,
                centerPercent: splitEditorVM.percentText(selectedCents, totalCents: totalCents),
                isEditingCenterAmount: splitEditorVM.isEditingAmount && splitEditorVM.editingGuestIndex == splitEditorVM.guestSelectedIndex,
                colorForActiveIdx: { splitEditorVM.colorForActiveIdx($0) },
                sumBefore: { splitEditorVM.sumBefore($0) },
                sumThrough: { splitEditorVM.sumThrough($0) },
                lastActiveIndex: { splitEditorVM.lastActiveIndex(idx: $0) },
                remainingExcluding: { splitEditorVM.remainingExcluding($0, totalCents: totalCents) },
                onTapEditAmount: {
                    splitEditorVM.startEditingAmount(for: splitEditorVM.guestSelectedIndex)
                    isAmountFieldFocused = true
                }
            )

            Spacer(minLength: 0)

            splitModePicker()
                .padding(.top, 7)
                .padding(.horizontal, 30)
        }
    }

    // MARK: - By items panel (seeded)
    func byItemPanel() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            splitPanelToolbar()
            Spacer()
            HStack {
                Text(splitEditorVM.claimMode
                     ? "Recipients claim their own items in chat."
                     : "Tap items to assign. Unassigned items split evenly between guests.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button(action: { showEditReceipt = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13))
                        Text("Edit")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingItems)
                .opacity(isLoadingItems ? 0.5 : 1)
            }

            // Tap-to-Claim variant toggle. When on, the cl flag ships in the
            // payload and recipients can claim items from the chat bubble.
            // Transition off→on wipes only OTHER guests' claims — the sender's
            // own pre-assignments survive so an accidental toggle doesn't
            // erase their work. The active guest gets locked to the sender.
            // Toggling off is non-destructive: claims stay put so you can
            // recover from a mis-tap without losing progress.
            Toggle(isOn: Binding(
                get: { splitEditorVM.claimMode },
                set: { newValue in
                    let wasOn = splitEditorVM.claimMode
                    splitEditorVM.claimMode = newValue
                    if newValue && !wasOn {
                        splitEditorVM.wipeNonSenderItemPartitions(
                            totalCents: totalCents, tipAmount: tipAmount
                        )
                        splitEditorVM.byItemSelectedGuestID = splitEditorVM.senderPersonID
                    }
                    splitEditorVM.syncByItemsToSplitDraft(
                        totalCents: totalCents, tipAmount: tipAmount
                    )
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 13))
                    Text("Let recipients claim")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .tint(.blue)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("Receipt items")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                if isLoadingItems {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Loading items...")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                } else if splitEditorVM.byItemItems.filter({ $0.isComplete }).isEmpty {
                    VStack(spacing: 12) {
                        Text("No items yet")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)

                        Button(action: { showEditReceipt = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text("Add items to receipt")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(splitEditorVM.byItemItems.indices, id: \.self) { idx in
                                let item = splitEditorVM.byItemItems[idx]

                                if item.isComplete {
                                    let isLast = idx == splitEditorVM.byItemItems.filter({ $0.isComplete }).count - 1

                                    HStack(spacing: 0) {
                                        // Left side is its own Button so the row's
                                        // 1-way claim/unclaim fires independently
                                        // from the right widget's Buttons (sibling
                                        // layout — no nested-Button hit-test race).
                                        Button {
                                            handleItemRowTap(item: item)
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.label)
                                                        .font(.system(size: 16, weight: .semibold))
                                                        .lineLimit(1)
                                                        .foregroundStyle(.primary)
                                                    Text(ReceiptDisplay.money(item.priceCents))
                                                        .font(.system(size: 13))
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer(minLength: 8)
                                            }
                                            .padding(.leading, 14)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        partitionRightWidget(for: item)
                                            .padding(.trailing, 14)
                                            .padding(.vertical, 12)
                                    }

                                    if !isLast {
                                        Divider().padding(.leading, 14)
                                    }
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .layoutPriority(1)
            Spacer()

            splitModePicker()
                .padding(.top, 7)
                .padding(.horizontal, 30)
        }
        // Picker dialog removed — the always-visible `+` button on each row
        // grows the split incrementally, so no hidden popup is needed.
    }

    // MARK: - Split panel toolbar (Back / Save)
    func splitPanelToolbar() -> some View {
        HStack {
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                splitEditorVM.restoreSnapshot()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    splitEditorVM.confirmed = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                let draft = splitEditorVM.buildSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
                receiptDraftVM.currentSplitDraft = draft
                onSelectMode(splitEditorVM.mode)
                onGuestsChanged(splitEditorVM.guests, splitEditorVM.includedIDs, splitEditorVM.payerID)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                // If we're saving non-claim byItems with items the user
                // didn't explicitly assign to anyone, surface the
                // "remaining items split evenly" rule via a transient toast
                // — the bill card will distribute those cents across guests,
                // which can otherwise look like a math error to a user who
                // expected unclaimed = $0 owed.
                if splitEditorVM.mode == .byItems && !splitEditorVM.claimMode {
                    let hasUnclaimed = splitEditorVM.byItemItems.contains { item in
                        guard item.isComplete else { return false }
                        return item.partition.claimedCents(priceCents: item.priceCents) < item.priceCents
                    }
                    if hasUnclaimed {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showSplitEvenlyBanner = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showSplitEvenlyBanner = false
                            }
                        }
                    }
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    splitEditorVM.confirmed = true
                }
            }) {
                Text("Save")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Split mode picker (shared)
    func splitModePicker(closesExpanded: Bool = false, capturesSnapshot: Bool = false) -> some View {
        let modes: [(SplitDraft.Mode, String)] = [
            (.byItems, "By Items"),
            (.equally, "Even Split"),
            (.custom,  "Custom")
        ]
        return VStack(alignment: .center, spacing: 7) {
            HStack(spacing: 12) {
                ForEach(modes, id: \.1) { (m, label) in
                    Button {
                        if capturesSnapshot { splitEditorVM.captureSnapshot() }
                        if closesExpanded {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                splitEditorVM.splitModesExpanded = false
                            }
                        }
                        splitEditorVM.selectMode(m, totalCents: totalCents)
                        onRequestExpand()
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        splitEditorVM.confirmed = false
                    } label: {
                        Text(label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(splitEditorVM.mode == m ? .white : .primary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 18).fill(splitEditorVM.mode == m ? .blue : buttonBase))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: - Guest navigation toolbar
    func guestNavigationToolbar() -> some View {
        HStack(spacing: 0) {
            Button(action: splitEditorVM.selectPreviousGuest) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(splitEditorVM.canGoPrevGuest ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!splitEditorVM.canGoPrevGuest)

            Spacer()

            HStack(spacing: 8) {
                Text(splitEditorVM.currentGuestName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: splitEditorVM.selectNextGuest) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(splitEditorVM.canGoNextGuest ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!splitEditorVM.canGoNextGuest)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Amount editing overlay
    @ViewBuilder
    func amountEditingOverlay() -> some View {
        if splitEditorVM.isEditingAmount, let guestIndex = splitEditorVM.editingGuestIndex {
            VStack(spacing: 12) {
                if splitEditorVM.activeGuests.indices.contains(guestIndex) {
                    Text(splitEditorVM.displayName(for: splitEditorVM.activeGuests[guestIndex], fallbackIndexInAllGuests: splitEditorVM.allIndex(for: splitEditorVM.activeGuests[guestIndex].id)))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .center, spacing: 2) {
                    Text("$")
                        .font(.system(size: 32, weight: .bold))
                    TextField("0", text: $splitEditorVM.amountInputText)
                        .font(.system(size: 32, weight: .bold))
                        .keyboardType(.decimalPad)
                        .focused($isAmountFieldFocused)
                        .multilineTextAlignment(.leading)                        .fixedSize()
                        .onChange(of: splitEditorVM.amountInputText) { _, newValue in
                            splitEditorVM.updateAmountLive(newValue, totalCents: totalCents)
                        }
                }

                let maxAmount = splitEditorVM.remainingExcluding(guestIndex, totalCents: totalCents)
                Text("Max: \(ReceiptDisplay.money(maxAmount))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        splitEditorVM.selectMode(.equally, totalCents: totalCents)
                        splitEditorVM.cancelAmountEdit()
                        isAmountFieldFocused = false
                    } label: {
                        Text("Equal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        splitEditorVM.cancelAmountEdit()
                        isAmountFieldFocused = false
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22))
        }
    }

    // MARK: - Partition-aware right-side widget

    /// Right-side widget — always shows the slot circles plus a leading `+`
    /// dotted circle (when more slots can be added). The `+` grows the split
    /// one denominator at a time, capped at the active guest count. Each
    /// circle is tappable: empty → claim, filled → unclaim. No Split picker
    /// — the always-visible shape makes "this item is split N ways" legible
    /// without a hidden dialog.
    @ViewBuilder
    func partitionRightWidget(for item: LineItemForm) -> some View {
        let (denom, slots) = SplitEditorViewModel.normalizedPartition(item.partition)

        HStack(spacing: 4) {
            if denom < splitEditorVM.activeCount {
                Button {
                    splitEditorVM.increaseDenominator(
                        itemId: item.id,
                        totalCents: totalCents,
                        tipAmount: tipAmount
                    )
                } label: {
                    dottedPlusBadge()
                }
                .buttonStyle(.plain)
            }

            ForEach(0..<denom, id: \.self) { i in
                let claimer = slots.indices.contains(i) ? slots[i] : nil
                Button {
                    splitEditorVM.togglePartitionShare(
                        itemId: item.id,
                        shareIndex: i,
                        totalCents: totalCents,
                        tipAmount: tipAmount
                    )
                } label: {
                    if let pid = claimer {
                        guestBadge(for: pid)
                    } else {
                        dottedSlotBadge()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func guestBadge(for pid: PersonID) -> some View {
        let fallbackIndex = splitEditorVM.guests.firstIndex(where: { $0.id == pid }) ?? 0
        let name = splitEditorVM.guests.first(where: { $0.id == pid }).map {
            splitEditorVM.displayName(for: $0, fallbackIndexInAllGuests: fallbackIndex)
        } ?? "Guest"
        ColoredCircleBadge(
            text: BadgeColors.initials(from: name, fallback: fallbackIndex),
            color: splitEditorVM.colorForGuestId(pid)
        )
    }

    /// Row-tap handler. Reads the normalized `(denom, slots)` so the same
    /// logic works whether the item is `.unclaimed` or `.shares(N, ...)`:
    ///   - Active has a slot → unclaim it.
    ///   - Active doesn't → fill the next empty slot.
    /// Tapping individual circles still gives finer control; the row tap is
    /// just a quick alternative.
    func handleItemRowTap(item: LineItemForm) {
        let activeID = splitEditorVM.byItemSelectedGuestID
        guard splitEditorVM.activeGuests.contains(where: { $0.id == activeID }) else { return }

        let (_, slots) = SplitEditorViewModel.normalizedPartition(item.partition)
        if let myIdx = slots.firstIndex(of: activeID) {
            splitEditorVM.togglePartitionShare(
                itemId: item.id, shareIndex: myIdx,
                totalCents: totalCents, tipAmount: tipAmount
            )
        } else if let emptyIdx = slots.firstIndex(where: { $0 == nil }) {
            splitEditorVM.togglePartitionShare(
                itemId: item.id, shareIndex: emptyIdx,
                totalCents: totalCents, tipAmount: tipAmount
            )
        }
    }

    /// Empty slot — dashed border, no `+` icon. Signals "claim me" without
    /// the pulse / `+` competing for attention next to the leading `+` button.
    @ViewBuilder
    private func dottedSlotBadge() -> some View {
        Circle()
            .fill(Color.gray.opacity(0.06))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                    )
            )
            .contentShape(Circle())
    }

    /// Leading `+` badge — dashed border with a `+` glyph inside. Grows the
    /// item's split by one slot per tap; hidden when the denominator already
    /// equals the active guest count.
    @ViewBuilder
    private func dottedPlusBadge() -> some View {
        Circle()
            .fill(Color.blue.opacity(0.08))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        Color.blue.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                    )
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.85))
            )
            .contentShape(Circle())
    }

}
