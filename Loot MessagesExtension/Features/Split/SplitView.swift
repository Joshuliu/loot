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

    // MARK: - Shared split-editor bottom dock

    /// Tunable layout constants for the shared bottom dock (guest list +
    /// Add Guest + picker slot). First-cut estimates — adjust on-device if
    /// the picker sits too high/low or the guest list scrolls too soon.
    enum SplitDockMetrics {
        /// Approx height of one guest row (badge + name + amount + paddings).
        static let guestRowApproxH: CGFloat = 56
        /// Max height the guest rows may occupy before they scroll
        /// internally instead of pushing Add Guest / the picker.
        static let guestRowsCap: CGFloat = 176
        /// Constant height reserved for the 3-button picker slot. Reserved
        /// even when the picker is hidden (confirmation card) so Add Guest
        /// never moves when switching screens / toggling the picker.
        static let pickerSlotH: CGFloat = 48
        /// Gap above the picker slot.
        static let pickerTopGap: CGFloat = 10
        /// Distance from the picker to the bottom edge — identical in
        /// every mode so the user's finger never has to move.
        static let bottomInset: CGFloat = 28
        /// Floor for the by-items receipt list before it scrolls.
        static let itemsMinH: CGFloat = 110
    }

    /// Internally-scrolling guest ROWS + pinned Add-Guest footer + Not
    /// Included + a CONSTANT-height picker slot. Shared by all three split
    /// editors AND the confirmation card screen so Add Guest and the
    /// picker sit a consistent distance off the bottom, and an overflowing
    /// guest list scrolls inside `guestRowsCap` instead of shoving the
    /// layout. The picker slot is always `pickerSlotH` tall — the real
    /// 3-button picker in the editors, an empty reserved space on the
    /// confirmation card — so neither screen-switching nor the picker
    /// toggling ever moves Add Guest. Deliberately has NO payer row —
    /// payer is chosen on the confirmation card only.
    @ViewBuilder
    func splitBottomDock(
        showPicker: Bool,
        showCustomRemaining: Bool = false,
        pickerClosesExpanded: Bool = false,
        pickerCapturesSnapshot: Bool = false
    ) -> some View {
        let rowsH = min(
            CGFloat(max(1, splitEditorVM.activeCount)) * SplitDockMetrics.guestRowApproxH,
            SplitDockMetrics.guestRowsCap
        )
        VStack(spacing: 6) {
            ScrollView { guestRowsList() }
                .frame(height: rowsH)

            if showCustomRemaining {
                guestCustomRemaining()
            }

            guestAddButton()
            guestNotIncluded()

            Group {
                if showPicker {
                    splitModePicker(
                        closesExpanded: pickerClosesExpanded,
                        capturesSnapshot: pickerCapturesSnapshot
                    )
                } else {
                    Color.clear
                }
            }
            .frame(height: SplitDockMetrics.pickerSlotH)
            .padding(.top, SplitDockMetrics.pickerTopGap)
            .padding(.horizontal, 10)
        }
        .padding(.bottom, SplitDockMetrics.bottomInset)
        .onChange(of: guestNameFocusedID) { _, newValue in
            // Clear inline name-edit state when the field loses focus
            // (moved here from the old guestList composer so it covers
            // every split-edit screen + the confirmation card).
            if newValue == nil {
                splitEditorVM.editingGuestNameID = nil
            }
        }
    }

    // MARK: - Guest donut view (used for equally + custom)

    func byGuestPanel(interactive: Bool) -> some View {
        let selectedCents = splitEditorVM.guestAmountsCents.indices.contains(splitEditorVM.guestSelectedIndex)
        ? splitEditorVM.guestAmountsCents[splitEditorVM.guestSelectedIndex]
        : 0

        let parts = splitEditorVM.moneyParts(selectedCents)

        let g = splitEditorVM.activeGuests.indices.contains(splitEditorVM.guestSelectedIndex) ? splitEditorVM.activeGuests[splitEditorVM.guestSelectedIndex] : nil
        let centerName = g.map { splitEditorVM.displayName(for: $0, fallbackIndexInAllGuests: splitEditorVM.allIndex(for: $0.id)) } ?? "Guest"

        return GeometryReader { geo in
            let H = geo.size.height
            // The RING is fixed at the top; a flexible Spacer below it
            // absorbs all slack so the bottom dock (guest list + Add Guest
            // + picker) is pinned the SAME distance off the bottom as
            // by-items. The guest list scrolls internally inside the dock.
            let ringH: CGFloat = 230   // fixed ring area (device-tune)

            VStack(alignment: .leading, spacing: 10) {
                splitPanelToolbar()

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
                .frame(height: ringH)
                // Part C: a bit more breathing room directly above/below
                // the ring.
                .padding(.top, 10)
                .padding(.bottom, 12)

                // Flexible slack sits ABOVE the dock so the dock is always
                // pinned the same distance off the bottom — identical to
                // by-items. Without this the picker teleported per mode.
                Spacer(minLength: 0)

                splitBottomDock(showPicker: true)
            }
            .frame(width: geo.size.width, height: H, alignment: .top)
        }
    }

    // MARK: - By items panel (seeded)
    // Dynamic by-items editor: fills the sheet. The receipt-items list
    // takes all free space first; as guests are added the guest section
    // grows and the items list shrinks — down to a floor, after which the
    // items list scrolls internally. The guest ROWS scroll independently
    // while "Add Guest" stays pinned as a footer. Heights are derived
    // from the live viewport (GeometryReader). The constants below are
    // first-cut estimates meant to be tuned on-device.
    func byItemPanel() -> some View {
        GeometryReader { geo in
            let H = geo.size.height

            VStack(alignment: .leading, spacing: 10) {
                splitPanelToolbar()

                HStack {
                    // On a tab, every member can already edit/claim anything
                    // regardless of this toggle (tab receipts are fully
                    // collaborative — see project_tab_receipts_collaborative).
                    // The toggle only changes the STARTING state, not who's
                    // allowed to edit, so the copy says so explicitly to
                    // resolve the "claim collapses to collaborative" confusion.
                    Text({
                        let isTabCompose = splitEditorVM.tabContextVM.activeTab != nil
                        switch (isTabCompose, splitEditorVM.claimMode) {
                        case (true, true):
                            return "Claim your own items. Tab members will claim their own."
                        case (true, false):
                            return "Assign items to each member."
                        case (false, true):
                            return "Claim your own items. Recipients will claim their own."
                        case (false, false):
                            return "Assign items to each guest."
                        }
                    }())
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

                // Tap-to-Claim variant toggle. When on, the cl flag ships in
                // the payload and recipients can claim items from the chat
                // bubble. Transition off→on wipes only OTHER guests' claims —
                // the sender's own pre-assignments survive so an accidental
                // toggle doesn't erase their work. The active guest gets
                // locked to the sender. Toggling off is non-destructive.
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

                // The items list is the flexible region here: it expands
                // to absorb all slack so the bottom dock is pinned the
                // SAME distance off the bottom as even/custom (no Spacer
                // between Add Guest and the picker → no stray gap).
                VStack(alignment: .leading, spacing: 8) {
                    Text("Receipt items")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    byItemsReceiptListBody()
                        .frame(minHeight: SplitDockMetrics.itemsMinH, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                splitBottomDock(showPicker: true)
            }
            .frame(width: geo.size.width, height: H, alignment: .top)
        }
    }

    // The receipt-items list body (loading / empty / scrollable list).
    // Height is governed by the caller; the inner ScrollView scrolls
    // within whatever it's given.
    @ViewBuilder
    func byItemsReceiptListBody() -> some View {
        if isLoadingItems {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Loading items...")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                            HStack(spacing: 4) {
                                                Text(ReceiptDisplay.money(item.priceCents))
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.secondary)
                                                if let annotation = splitAnnotation(for: item) {
                                                    Text(annotation)
                                                        .font(.system(size: 13))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
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
                    let unclaimedCents = splitEditorVM.byItemItems.reduce(0) { acc, item in
                        guard item.isComplete else { return acc }
                        return acc + max(0, item.priceCents - item.partition.claimedCents(priceCents: item.priceCents))
                    }
                    if unclaimedCents > 0 {
                        splitEvenlyUnclaimedCents = unclaimedCents
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
        // Just the buttons row — no wrapping padding. The shared dock
        // gives it a constant-height slot so it renders pixel-identically
        // and never moves vertically between modes.
        return HStack(spacing: 8) {
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 18).fill(splitEditorVM.mode == m ? .blue : buttonBase))
                }
                .buttonStyle(.plain)
            }
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

    /// "(split N ways)" annotation shown next to an item's price when the
    /// item's partition is multi-way (denominator > 1). Mirrors
    /// EditSplitView / SplitsSummaryView so compose, claim, and edit flows
    /// describe item structure identically — pressing `+` (which bumps the
    /// denominator) updates this immediately.
    func splitAnnotation(for item: LineItemForm) -> String? {
        let (denom, _) = SplitEditorViewModel.normalizedPartition(item.partition)
        guard denom > 1 else { return nil }
        return "(split \(denom) ways)"
    }

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

    /// Leading `+` badge — grows the item's split by one slot per tap;
    /// hidden when the denominator already equals the active guest count.
    @ViewBuilder
    private func dottedPlusBadge() -> some View {
        // Plain `+` glyph, NOT a circle — a circle reads as a tappable claim
        // slot ("assign me here") instead of an "add another slot" action.
        // Mirrors EditSplitView.dottedPlusBadge so compose + edit match.
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.blue.opacity(0.85))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }

}
