//
//  EditSplitView.swift
//  Loot
//
//  Post-send split editor. Converts SplitPayload → SplitDraft for editing,
//  then converts back and persists to Firestore.
//

import SwiftUI
import UIKit

struct EditSplitView: View {
    let payload: LootMessagePayload
    let docId: String
    let onSave: (LootMessagePayload) -> Void
    let onCancel: () -> Void

    // Split state (initialized from payload in init)
    @State private var mode: SplitDraft.Mode
    @State private var guests: [Person]
    @State private var includedIDs: Set<PersonID>
    @State private var payerID: PersonID
    @State private var guestAmountsCents: [Int]
    @State private var guestSelectedIndex: Int = 0
    @State private var byItemItems: [LineItemForm]
    @State private var byItemSelectedGuestID: PersonID
    @State private var slotPersonIDs: [PersonID]

    // Editing state
    @State private var isEditingAmount = false
    @State private var editingGuestIndex: Int? = nil
    @State private var amountInputText = ""
    @FocusState private var isAmountFieldFocused: Bool
    @State private var editingGuestNameID: PersonID? = nil
    @FocusState private var guestNameFocusedID: PersonID?
    @State private var uidDisplayNames: [String: String] = [:]
    /// Item ID currently presenting the split-denominator picker, or nil.
    @State private var splitPickerItemId: UUID? = nil

    private var localUserId: String { KeychainHelper.getOrCreateUserId() }

    init(payload: LootMessagePayload, docId: String, onSave: @escaping (LootMessagePayload) -> Void, onCancel: @escaping () -> Void) {
        self.payload = payload
        self.docId = docId
        self.onSave = onSave
        self.onCancel = onCancel

        let (draft, slotPersonIDs) = payload.s.toSplitDraft(
            receiptItems: payload.r.i,
            totalCents: payload.s.tot
        )

        _slotPersonIDs = State(initialValue: slotPersonIDs)
        _guests = State(initialValue: draft.guests)
        _includedIDs = State(initialValue: draft.includedIDs)
        _payerID = State(initialValue: draft.payerID)

        let draftMode = draft.mode
        _mode = State(initialValue: draftMode)

        let active = draft.includedGuests
        let activeCount = active.count

        // Compute initial amounts
        var amounts = draft.perGuestCents
        if draftMode == .equally {
            amounts = splitCentsEvenly(total: payload.s.tot, count: activeCount)
        }
        _guestAmountsCents = State(initialValue: amounts)

        _byItemSelectedGuestID = State(initialValue: active.first?.id ?? PersonID(rawValue: ""))
        // Pass partition through directly (Phase 8b) so uneven shares and
        // custom claims survive an Edit Split round-trip. The legacy Set-based
        // accessor on LineItemForm still works for the existing tap-toggle UI,
        // but the underlying partition is preserved for untouched items.
        _byItemItems = State(initialValue: draft.items.map { item in
            LineItemForm(
                id: item.id,
                label: item.label,
                priceText: Money(cents: item.priceCents).inputString,
                partition: item.partition
            )
        })
    }

    private var activeGuests: [Person] { guests.filter { includedIDs.contains($0.id) } }
    private var activeCount: Int { activeGuests.count }

    private var totalCents: Int { payload.s.tot }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Mode picker
                splitModePicker()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider().padding(.top, 12)

                // Main content
                ScrollView {
                    VStack(spacing: 16) {
                        // Payer selector
                        payerSelector()

                        // Guest list
                        guestListView()

                        // By-items panel
                        if mode == .byItems {
                            byItemsPanel()
                        }

                        // Custom mode remaining
                        if mode == .custom {
                            customRemainingView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 80)
                }

                // Amount editing overlay
                if isEditingAmount {
                    amountEditingOverlay()
                }
            }
            .navigationTitle("Edit Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .task(id: guestUIDsTaskKey) {
            await loadUIDDisplayNamesIfNeeded()
        }
    }

    // MARK: - Save

    private func save() {
        // DEBUG: Phase 13a investigation — by-items save produces zero owed amounts.
        print("[EditSplit.save] mode=\(mode) totalCents=\(totalCents)")
        print("[EditSplit.save] guests=\(guests.map { "(name=\($0.displayName) id=\($0.id.rawValue) uid=\($0.userId ?? "nil"))" })")
        print("[EditSplit.save] includedIDs=\(includedIDs.map(\.rawValue))")
        print("[EditSplit.save] byItemItems=\(byItemItems.map { "(label=\($0.label) priceText=\($0.priceText) priceCents=\($0.priceCents) isComplete=\($0.isComplete) assigned=\($0.assignedGuestIds.map(\.rawValue)))" })")

        // Build SplitDraft from current state. Pass partition through (not
        // the flat Set view) so uneven shares / custom claims aren't flattened.
        let items: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { it in
                SplitDraft.Item(
                    id: it.id,
                    label: it.label,
                    priceCents: it.priceCents,
                    partition: it.partition
                )
            }
        print("[EditSplit.save] items_after_filter=\(items.map { "(label=\($0.label) priceCents=\($0.priceCents) assigned=\($0.assignedGuestIds.map(\.rawValue)))" })")

        let draft = SplitDraft(
            guests: guests,
            includedIDs: includedIDs,
            payerID: payerID,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: guestAmountsCents,
            items: items,
            feesCents: payload.s.f ?? 0,
            discountCents: payload.s.d ?? 0,
            taxCents: payload.s.tx ?? 0,
            tipCents: payload.s.tip ?? 0,
            // Preserve Tap-to-Claim flag so SplitMath computes owed amounts in
            // claim mode (unclaimed cents stay unattributed instead of even-
            // splitting onto everyone).
            claimMode: payload.s.cl ?? false
        )

        // Convert draft back to SplitPayload
        let newSplit = SplitPayload.from(
            draft: draft,
            participantCount: guests.count,
            totalCents: totalCents
        )
        print("[EditSplit.save] newSplit.o=\(newSplit.o) newSplit.tot=\(newSplit.tot) mode=\(newSplit.m)")

        // Preserve paid status from original split
        var updatedPayload = payload
        updatedPayload.s = newSplit
        updatedPayload.s.pd = payload.s.pd

        // Update receipt items with the new partition wire fields. Encode
        // through `ItemPartition.wireFields(guests:)` so shares (with possibly
        // some nil slots) and custom claims survive the round-trip — the
        // earlier code cleared sh/cu unconditionally, degrading partition
        // fidelity to legacy flat shares.
        if mode == .byItems {
            // Build the wire-format guest array that wireFields/slotIndex(for:)
            // expect, plus a remap dict from EditSplitView's draft-internal
            // PersonIDs (random UUIDs for anonymous slots) to wire-canonical
            // PersonIDs (uid or "slot-N"). Same boundary fix as in
            // SplitPayload.from(draft:) — without it, anonymous-slot claims
            // get dropped by slotIndex(for:) lookup.
            let wireGuests: [SplitPayload.Guest] = guests.map { p in
                SplitPayload.Guest(n: p.displayName, inc: includedIDs.contains(p.id), uid: p.userId)
            }
            let remap: [PersonID: PersonID] = Dictionary(uniqueKeysWithValues:
                guests.enumerated().map { (idx, p) in
                    let canonical = (p.userId?.isEmpty == false)
                        ? PersonID(rawValue: p.userId!)
                        : PersonID(rawValue: "slot-\(idx)")
                    return (p.id, canonical)
                })

            updatedPayload.r.i = updatedPayload.r.i.enumerated().map { idx, item in
                var updated = item
                if byItemItems.indices.contains(idx) {
                    let canonical = byItemItems[idx].partition.remappingPersonIDs(remap)
                    let wire = canonical.wireFields(guests: wireGuests)
                    updated.rs = wire.rs
                    updated.sh = wire.sh
                    updated.cu = wire.cu
                }
                return updated
            }
        }

        onSave(updatedPayload)
    }

    // MARK: - Mode Picker

    private func splitModePicker() -> some View {
        let modes: [(SplitDraft.Mode, String)] = [
            (.byItems, "By Items"),
            (.equally, "Even Split"),
            (.custom, "Custom")
        ]
        return HStack(spacing: 12) {
            ForEach(modes, id: \.1) { (m, label) in
                Button {
                    selectMode(m)
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(mode == m ? .white : .primary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 18).fill(mode == m ? .blue : Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Payer Selector

    private func payerSelector() -> some View {
        HStack(spacing: 4) {
            Text("Paid by")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Menu {
                ForEach(activeGuests) { guest in
                    Button {
                        payerID = guest.id
                    } label: {
                        HStack {
                            Text(displayName(for: guest))
                            if guest.id == payerID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(payerDisplayName())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.blue)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }

            Spacer()

            Text("Total: \(ReceiptDisplay.money(totalCents))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Guest List

    private func guestListView() -> some View {
        VStack(spacing: 0) {
            ForEach(0..<activeCount, id: \.self) { i in
                let guest = activeGuests[i]
                let gid = guest.id
                let isMe = guest.isMe(localUserId: localUserId)
                let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSelected: Bool = mode == .byItems
                    ? gid == byItemSelectedGuestID
                    : i == guestSelectedIndex

                HStack(spacing: 8) {
                    // Badge
                    ColoredCircleBadge(
                        text: BadgeColors.initials(
                            from: displayName(for: guest),
                            fallback: allIndex(for: gid) ?? i
                        ),
                        color: colorForActiveIdx(i)
                    )

                    // Name
                    if editingGuestNameID == gid && canEditName(for: guest) {
                        TextField("Guest name", text: Binding(
                            get: { guests.first(where: { $0.id == gid })?.displayName ?? "" },
                            set: { newValue in
                                if let idx = guests.firstIndex(where: { $0.id == gid }) {
                                    guests[idx].displayName = newValue
                                }
                            }
                        ))
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .focused($guestNameFocusedID, equals: gid)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { editingGuestNameID = nil }
                    } else {
                        Text(displayName(for: guest))
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(trimmed.isEmpty && !isMe ? .secondary : .primary)
                            .onTapGesture {
                                if canEditName(for: guest) {
                                    editingGuestNameID = gid
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        guestNameFocusedID = gid
                                    }
                                }
                            }
                    }

                    Spacer()

                    // Amount
                    if mode == .byItems {
                        let guestCents = byItemsGuestCents(for: gid)
                        Text(ReceiptDisplay.money(guestCents))
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(guestCents > 0 ? .primary : .secondary)
                    } else {
                        Text(ReceiptDisplay.money(guestAmountsCents.indices.contains(i) ? guestAmountsCents[i] : 0))
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                startEditingAmount(for: i)
                            }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editingGuestNameID != nil && editingGuestNameID != gid {
                        editingGuestNameID = nil
                        guestNameFocusedID = nil
                    }
                    if mode == .byItems { byItemSelectedGuestID = gid }
                    else { guestSelectedIndex = i }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isSelected && mode != .equally ? Color(.secondarySystemBackground) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .onChange(of: guestNameFocusedID) { _, newValue in
            if newValue == nil { editingGuestNameID = nil }
        }
    }

    // MARK: - By Items Panel

    private func byItemsPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((payload.s.cl ?? false)
                 ? "Edit splits. Recipients can also claim from chat."
                 : "Tap items to assign. Unassigned items split evenly between guests.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                let completeItems = byItemItems.filter { $0.isComplete }
                ForEach(completeItems.indices, id: \.self) { idx in
                    let itemIdx = byItemItems.firstIndex(where: { $0.id == completeItems[idx].id })!
                    let item = byItemItems[itemIdx]

                    HStack(spacing: 0) {
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

                    if idx < completeItems.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .confirmationDialog(
            "Split into how many?",
            isPresented: Binding(
                get: { splitPickerItemId != nil },
                set: { presented in if !presented { splitPickerItemId = nil } }
            ),
            titleVisibility: .visible,
            presenting: splitPickerItemId
        ) { itemId in
            let inlineMax = max(2, min(9, activeCount))
            ForEach(2...max(inlineMax, 2), id: \.self) { n in
                Button("Split \(n) ways") {
                    setItemDenominator(itemId: itemId, denominator: n)
                    splitPickerItemId = nil
                }
            }
            Button("Cancel", role: .cancel) { splitPickerItemId = nil }
        }
    }

    // MARK: - Partition widget (post-send edit)

    @ViewBuilder
    private func partitionRightWidget(for item: LineItemForm) -> some View {
        switch item.partition {
        case .unclaimed:
            Button {
                splitPickerItemId = item.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Split")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(Color.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .shares(let denom, let slots):
            if denom == 1, slots.indices.contains(0), let pid = slots[0] {
                guestBadge(for: pid)
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<denom, id: \.self) { i in
                        let claimer = slots.indices.contains(i) ? slots[i] : nil
                        Button {
                            togglePartitionShare(itemId: item.id, shareIndex: i)
                        } label: {
                            if let pid = claimer {
                                guestBadge(for: pid)
                            } else {
                                hollowCircleBadge()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case .custom(let claims):
            HStack(spacing: 4) {
                ForEach(claims, id: \.personID) { c in
                    guestBadge(for: c.personID)
                }
            }
        }
    }

    @ViewBuilder
    private func guestBadge(for pid: PersonID) -> some View {
        let fallbackIndex = guests.firstIndex(where: { $0.id == pid }) ?? 0
        let name = guests.first(where: { $0.id == pid }).map { displayName(for: $0) } ?? "Guest"
        ColoredCircleBadge(
            text: BadgeColors.initials(from: name, fallback: fallbackIndex),
            color: colorForGuestId(pid)
        )
    }

    @ViewBuilder
    private func hollowCircleBadge() -> some View {
        Circle()
            .fill(Color.gray.opacity(0.12))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .symbolEffect(.pulse, options: .repeating)
            )
            .contentShape(Circle())
    }

    // MARK: - Partition mutators

    /// Row-tap handler — same semantics as compose's byItemPanel:
    ///   - `.unclaimed` → claim active full (`shares(1, [active])`)
    ///   - `.shares(1, [active])` → unclaim
    ///   - `.shares(1, [other])` → no-op
    ///   - `.shares(N>1, ...)` → unclaim active's slot if held; else fill next empty
    ///   - `.custom` → no-op
    private func handleItemRowTap(item: LineItemForm) {
        let activeID = byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }
        guard let idx = byItemItems.firstIndex(where: { $0.id == item.id }) else { return }

        switch byItemItems[idx].partition {
        case .unclaimed:
            byItemItems[idx].partition = .shares(denominator: 1, slots: [activeID])
        case .shares(let denom, let slots) where denom == 1:
            if slots.first == activeID {
                byItemItems[idx].partition = .unclaimed
            }
        case .shares(_, let slots):
            if let myIdx = slots.firstIndex(of: activeID) {
                togglePartitionShare(itemId: item.id, shareIndex: myIdx)
            } else if let emptyIdx = slots.firstIndex(where: { $0 == nil }) {
                togglePartitionShare(itemId: item.id, shareIndex: emptyIdx)
            }
        case .custom:
            break
        }
    }

    /// Picker-confirmed denominator — sets shares(N, [active, nil, …]).
    private func setItemDenominator(itemId: UUID, denominator: Int) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard denominator >= 1 else { return }
        let activeID = byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }

        var slots: [PersonID?] = Array(repeating: nil, count: denominator)
        slots[0] = activeID
        byItemItems[idx].partition = .shares(denominator: denominator, slots: slots)
    }

    /// Per-circle toggle. Tap a filled slot to unclaim it; tap an empty slot
    /// to claim for active (auto-rotating to the next un-placed active guest
    /// if active is already in another slot — same model as compose).
    private func togglePartitionShare(itemId: UUID, shareIndex: Int) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard case .shares(let denom, var slots) = byItemItems[idx].partition else { return }
        guard slots.indices.contains(shareIndex) else { return }

        let activeID = byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }

        if slots[shareIndex] != nil {
            slots[shareIndex] = nil
        } else {
            let claimer: PersonID? = {
                if !slots.contains(activeID) { return activeID }
                return activeGuests.first(where: { !slots.contains($0.id) })?.id
            }()
            guard let claimer else { return }
            slots[shareIndex] = claimer
        }

        if slots.allSatisfy({ $0 == nil }) {
            byItemItems[idx].partition = .unclaimed
        } else {
            byItemItems[idx].partition = .shares(denominator: denom, slots: slots)
        }
    }

    // MARK: - Custom Remaining

    private func customRemainingView() -> some View {
        let remaining = max(0, totalCents - guestAmountsCents.reduce(0, +))
        return HStack {
            Text("Remaining")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text(ReceiptDisplay.money(remaining))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(remaining == 0 ? .secondary : .orange)
        }
    }

    // MARK: - Amount Editing Overlay

    private func amountEditingOverlay() -> some View {
        VStack(spacing: 12) {
            if let guestIndex = editingGuestIndex, activeGuests.indices.contains(guestIndex) {
                Text(displayName(for: activeGuests[guestIndex]))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(alignment: .center, spacing: 2) {
                    Text("$")
                        .font(.system(size: 32, weight: .bold))
                    TextField("0", text: $amountInputText)
                        .font(.system(size: 32, weight: .bold))
                        .keyboardType(.decimalPad)
                        .focused($isAmountFieldFocused)
                        .multilineTextAlignment(.leading)
                        .fixedSize()
                        .onChange(of: amountInputText) { _, newValue in
                            updateAmountLive(newValue)
                        }
                }

                let maxAmount = remainingExcluding(guestIndex)
                Text("Max: \(ReceiptDisplay.money(maxAmount))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        selectMode(.equally)
                        cancelAmountEdit()
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
                        cancelAmountEdit()
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
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22))
    }

    // MARK: - Helpers

    private func canEditName(for guest: Person) -> Bool {
        let uid = guest.userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return uid.isEmpty
    }

    private func displayName(for guest: Person) -> String {
        let t = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if guest.isMe(localUserId: localUserId) {
            let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            return me.isEmpty ? "Me" : me
        }
        if let idx = guests.firstIndex(where: { $0.id == guest.id }) {
            return "Guest \(idx + 1)"
        }
        return "Guest"
    }

    private var guestUIDsTaskKey: String {
        guests.compactMap(\.userId)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
    }

    private func loadUIDDisplayNamesIfNeeded() async {
        let myUid = KeychainHelper.getOrCreateUserId()
        let uids = Set(
            guests.compactMap(\.userId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != myUid }
        )
        guard !uids.isEmpty else { return }

        for uid in uids where uidDisplayNames[uid] == nil {
            do {
                if let name = try await TabService.shared.fetchUserDisplayName(userId: uid),
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await MainActor.run {
                        uidDisplayNames[uid] = name
                        // Match tab-style display behavior: known users carry a concrete name value.
                        for idx in guests.indices {
                            guard guests[idx].userId == uid else { continue }
                            let trimmedExisting = guests[idx].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmedExisting.isEmpty {
                                guests[idx].displayName = name
                            }
                        }
                    }
                }
            } catch {
                print("[EditSplitView] Failed to fetch name for \(uid): \(error)")
            }
        }
    }

    private func payerDisplayName() -> String {
        if let guest = activeGuests.first(where: { $0.id == payerID }) {
            return displayName(for: guest)
        }
        return "Guest"
    }

    private func allIndex(for id: PersonID) -> Int? {
        guests.firstIndex(where: { $0.id == id })
    }

    private func colorForActiveIdx(_ i: Int) -> Color {
        guard activeGuests.indices.contains(i) else { return BadgeColors.palette[0] }
        return colorForGuestId(activeGuests[i].id)
    }

    private func colorForGuestId(_ id: PersonID) -> Color {
        guard let idx = guests.firstIndex(where: { $0.id == id }) else {
            return BadgeColors.palette[0]
        }
        return BadgeColors.color(for: idx)
    }


    private func byItemsGuestCents(for guestId: PersonID) -> Int {
        byItemsGuestSubtotalCents(
            guestID: guestId,
            guestOrder: guests.map(\.id),
            items: byItemItems.map { item in
                (priceCents: item.priceCents, assignedGuestIDs: Array(item.assignedGuestIds))
            }
        )
    }

    private func remainingExcluding(_ idx: Int) -> Int {
        guard !guestAmountsCents.isEmpty, guestAmountsCents.count == activeCount else { return totalCents }
        let totalAssigned = guestAmountsCents.reduce(0, +)
        let current = guestAmountsCents.indices.contains(idx) ? guestAmountsCents[idx] : 0
        return max(0, totalCents - (totalAssigned - current))
    }

    // MARK: - Mode Switching

    private func selectMode(_ newMode: SplitDraft.Mode) {
        mode = newMode
        ensureGuestArrays()

        if newMode == .equally {
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: activeCount)
        }
        if newMode == .custom {
            // Keep existing amounts or reset
            if guestAmountsCents.reduce(0, +) == 0 {
                guestAmountsCents = Array(repeating: 0, count: activeCount)
            }
        }
        if newMode == .byItems {
            byItemSelectedGuestID = activeGuests.first?.id ?? PersonID(rawValue: "")
        }
    }

    private func ensureGuestArrays() {
        let cnt = activeCount
        if guestAmountsCents.count != cnt {
            guestAmountsCents = Array(guestAmountsCents.prefix(cnt))
            if guestAmountsCents.count < cnt {
                guestAmountsCents.append(contentsOf: Array(repeating: 0, count: cnt - guestAmountsCents.count))
            }
        }
        if cnt > 0 {
            guestSelectedIndex = min(max(guestSelectedIndex, 0), cnt - 1)
        }
    }

    // MARK: - Amount Editing

    private func startEditingAmount(for guestIndex: Int) {
        guard mode != .byItems else { return }
        if mode == .equally {
            mode = .custom
            ensureGuestArrays()
        }
        guestSelectedIndex = guestIndex
        editingGuestIndex = guestIndex
        let currentCents = guestAmountsCents.indices.contains(guestIndex) ? guestAmountsCents[guestIndex] : 0
        if currentCents == 0 {
            amountInputText = ""
        } else {
            let dollars = currentCents / 100
            let cents = currentCents % 100
            amountInputText = cents == 0 ? "\(dollars)" : String(format: "%d.%02d", dollars, cents)
        }
        isEditingAmount = true
        isAmountFieldFocused = true
    }

    private func cancelAmountEdit() {
        isEditingAmount = false
        editingGuestIndex = nil
        amountInputText = ""
        isAmountFieldFocused = false
    }

    private func updateAmountLive(_ input: String) {
        guard let guestIndex = editingGuestIndex else { return }

        let cleaned = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")

        guard !cleaned.isEmpty else {
            guestAmountsCents[guestIndex] = 0
            return
        }

        let newCents: Int
        if cleaned.contains(".") {
            let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            let cents = Int(String(cents2.prefix(2))) ?? 0
            newCents = dollars * 100 + cents
        } else {
            newCents = (Int(cleaned) ?? 0) * 100
        }

        let maxAllowed = remainingExcluding(guestIndex)
        guestAmountsCents[guestIndex] = min(max(newCents, 0), maxAllowed)
    }

    // Note: legacy `toggleAssignment` (flat Set-based tap-toggle) replaced by
    // the partition-aware `handleItemRowTap` / `togglePartitionShare` flow
    // higher up in this file. Compose-side parity for byItems editing.
}
