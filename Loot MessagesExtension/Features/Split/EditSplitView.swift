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
    @State private var guests: [SplitGuest]
    @State private var payerGuestId: UUID
    @State private var guestAmountsCents: [Int]
    @State private var guestSelectedIndex: Int = 0
    @State private var byItemItems: [DraftReceiptItem]
    @State private var byItemSelectedGuestId: UUID
    @State private var slotUUIDs: [UUID]

    // Editing state
    @State private var isEditingAmount = false
    @State private var editingGuestIndex: Int? = nil
    @State private var amountInputText = ""
    @FocusState private var isAmountFieldFocused: Bool
    @State private var editingGuestNameId: UUID? = nil
    @FocusState private var guestNameFocusedId: UUID?

    init(payload: LootMessagePayload, docId: String, onSave: @escaping (LootMessagePayload) -> Void, onCancel: @escaping () -> Void) {
        self.payload = payload
        self.docId = docId
        self.onSave = onSave
        self.onCancel = onCancel

        let (draft, uuids) = payload.s.toSplitDraft(
            receiptItems: payload.r.i,
            totalCents: payload.s.tot
        )

        _slotUUIDs = State(initialValue: uuids)
        _guests = State(initialValue: draft.guests)
        _payerGuestId = State(initialValue: draft.payerGuestId)

        let draftMode = draft.mode
        _mode = State(initialValue: draftMode)

        let active = draft.guests.filter { $0.isIncluded }
        let activeCount = active.count

        // Compute initial amounts
        var amounts = draft.perGuestCents
        if draftMode == .equally {
            amounts = Self.computeEqualSplit(total: payload.s.tot, count: activeCount)
        }
        _guestAmountsCents = State(initialValue: amounts)

        _byItemSelectedGuestId = State(initialValue: active.first?.id ?? UUID())
        _byItemItems = State(initialValue: draft.items.map { item in
            DraftReceiptItem(
                id: item.id,
                label: item.label,
                price: ReceiptDisplay.money(item.priceCents),
                assignedGuestIds: Set(item.assignedGuestIds)
            )
        })
    }

    private static func computeEqualSplit(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }

    private var activeGuests: [SplitGuest] { guests.filter { $0.isIncluded } }
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
    }

    // MARK: - Save

    private func save() {
        // Build SplitDraft from current state
        let items: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { it in
                SplitDraft.Item(
                    id: it.id,
                    label: it.label,
                    priceCents: stringToCents(it.price),
                    assignedGuestIds: it.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }
                )
            }

        // Fold legacy discountCents into feesCents
        let effectiveFees = (payload.s.f ?? 0) - (payload.s.d ?? 0)
        let draft = SplitDraft(
            guests: guests,
            payerGuestId: payerGuestId,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: guestAmountsCents,
            items: items,
            feesCents: effectiveFees,
            taxCents: payload.s.tx ?? 0,
            tipCents: payload.s.tip ?? 0
        )

        // Convert draft back to SplitPayload
        let newSplit = SplitPayload.from(
            draft: draft,
            participantCount: guests.count,
            totalCents: totalCents
        )

        // Preserve paid status from original split
        var updatedPayload = payload
        updatedPayload.s = newSplit
        updatedPayload.s.pd = payload.s.pd

        // Update receipt items with new responsible slots if by-items mode
        if mode == .byItems {
            let slotIndexByUUID: [UUID: Int] = Dictionary(
                uniqueKeysWithValues: guests.enumerated().map { ($1.id, $0) }
            )
            updatedPayload.r.i = updatedPayload.r.i.enumerated().map { idx, item in
                var updated = item
                if byItemItems.indices.contains(idx) {
                    updated.rs = byItemItems[idx].assignedGuestIds
                        .compactMap { slotIndexByUUID[$0] }
                        .sorted()
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
                        payerGuestId = guest.id
                    } label: {
                        HStack {
                            Text(displayName(for: guest))
                            if guest.id == payerGuestId {
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
                let isSelected: Bool = mode == .byItems
                    ? gid == byItemSelectedGuestId
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
                    if editingGuestNameId == gid && !guest.isMe {
                        TextField("Guest name", text: Binding(
                            get: { guests.first(where: { $0.id == gid })?.name ?? "" },
                            set: { newValue in
                                if let idx = guests.firstIndex(where: { $0.id == gid }) {
                                    guests[idx].name = newValue
                                }
                            }
                        ))
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .focused($guestNameFocusedId, equals: gid)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { editingGuestNameId = nil }
                    } else {
                        Text(displayName(for: guest))
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(guest.trimmedName.isEmpty && !guest.isMe ? .secondary : .primary)
                            .onTapGesture {
                                if !guest.isMe {
                                    editingGuestNameId = gid
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        guestNameFocusedId = gid
                                    }
                                }
                            }
                    }

                    Spacer()

                    // Amount
                    if mode == .byItems {
                        let guestCents = byItemItems
                            .filter { $0.assignedGuestIds.contains(gid) }
                            .reduce(0) { acc, item in
                                let n = max(1, item.assignedGuestIds.count)
                                return acc + stringToCents(item.price) / n
                            }
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
                    if editingGuestNameId != nil && editingGuestNameId != gid {
                        editingGuestNameId = nil
                        guestNameFocusedId = nil
                    }
                    if mode == .byItems { byItemSelectedGuestId = gid }
                    else { guestSelectedIndex = i }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isSelected && mode != .equally ? Color(.secondarySystemBackground) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .onChange(of: guestNameFocusedId) { _, newValue in
            if newValue == nil { editingGuestNameId = nil }
        }
    }

    // MARK: - By Items Panel

    private func byItemsPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap items to assign to the selected guest")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                let completeItems = byItemItems.filter { $0.isComplete }
                ForEach(completeItems.indices, id: \.self) { idx in
                    let itemIdx = byItemItems.firstIndex(where: { $0.id == completeItems[idx].id })!
                    let item = byItemItems[itemIdx]

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            Text(ReceiptDisplay.money(stringToCents(item.price)))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            ForEach(item.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }, id: \.self) { gid in
                                let fallbackIndex = guests.firstIndex(where: { $0.id == gid }) ?? 0
                                let name = guests.first(where: { $0.id == gid }).map { displayName(for: $0) } ?? "Guest"
                                ColoredCircleBadge(
                                    text: BadgeColors.initials(from: name, fallback: fallbackIndex),
                                    color: colorForGuestId(gid)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleAssignment(itemId: item.id) }

                    if idx < completeItems.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
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

    private func displayName(for guest: SplitGuest) -> String {
        let t = guest.trimmedName
        if !t.isEmpty { return t }
        if guest.isMe {
            let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            return me.isEmpty ? "Me" : me
        }
        if let idx = guests.firstIndex(where: { $0.id == guest.id }) {
            return "Guest \(idx + 1)"
        }
        return "Guest"
    }

    private func payerDisplayName() -> String {
        if let guest = activeGuests.first(where: { $0.id == payerGuestId }) {
            return displayName(for: guest)
        }
        return "Guest"
    }

    private func allIndex(for id: UUID) -> Int? {
        guests.firstIndex(where: { $0.id == id })
    }

    private func colorForActiveIdx(_ i: Int) -> Color {
        guard activeGuests.indices.contains(i) else { return BadgeColors.palette[0] }
        return colorForGuestId(activeGuests[i].id)
    }

    private func colorForGuestId(_ id: UUID) -> Color {
        guard let idx = guests.firstIndex(where: { $0.id == id }) else {
            return BadgeColors.palette[0]
        }
        return BadgeColors.color(for: idx)
    }

    private func equalSplitCents(total: Int, count: Int) -> [Int] {
        Self.computeEqualSplit(total: total, count: count)
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
            guestAmountsCents = equalSplitCents(total: totalCents, count: activeCount)
        }
        if newMode == .custom {
            // Keep existing amounts or reset
            if guestAmountsCents.reduce(0, +) == 0 {
                guestAmountsCents = Array(repeating: 0, count: activeCount)
            }
        }
        if newMode == .byItems {
            byItemSelectedGuestId = activeGuests.first?.id ?? UUID()
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

    // MARK: - By Items

    private func toggleAssignment(itemId: UUID) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard byItemItems[idx].isComplete else { return }

        let guestId = byItemSelectedGuestId
        guard activeGuests.contains(where: { $0.id == guestId }) else { return }

        if byItemItems[idx].assignedGuestIds.contains(guestId) {
            byItemItems[idx].assignedGuestIds.remove(guestId)
        } else {
            byItemItems[idx].assignedGuestIds.insert(guestId)
        }
    }
}
