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
    /// The saved receipt photo (if the bill was sent with one). Only used
    /// post-send to RECOVER line items via re-OCR when a bill was sent
    /// without itemization and the editor then switches to By Items —
    /// there's no scan transcript post-send, so we re-run OCR + Phase 2 on
    /// this image. `nil` ⇒ no image was attached ⇒ no recovery is possible.
    let receiptImage: UIImage?
    let onSave: (LootMessagePayload) -> Void
    let onCancel: () -> Void

    /// True while re-OCR + Phase 2 is in flight (the "Load receipt items"
    /// action). Drives the By Items empty-state spinner.
    @State private var isLoadingItems = false
    /// Non-nil after a failed recovery so the empty state can offer a retry.
    @State private var itemsLoadError: String? = nil

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

    private var localUserId: String { KeychainHelper.getOrCreateUserId() }

    /// True only for the ORIGINAL bill creator. `payload.su` is set once at
    /// send time and preserved across claim re-broadcasts, so a recipient who
    /// claims and auto-sends an updated bill is NOT the sender. Only the
    /// sender may change the split mode (even / custom / by-items); recipients
    /// use this view solely to claim their items.
    private var isSender: Bool {
        guard let su = payload.su, !su.isEmpty else { return false }
        return su == localUserId
    }

    /// A receipt attached to a tab. Tab receipts are fully collaborative —
    /// ANY member can edit anything (membership is already enforced
    /// upstream: SplitsSummaryView locks non-members out). So tab receipts
    /// get the full editor, never the recipient-claim-only view.
    private var isTabReceipt: Bool {
        (payload.tid?.isEmpty == false)
    }

    /// Who gets the FULL editor (mode picker, payer, guest list, custom
    /// remaining) vs. the recipient claim-only view: the original sender
    /// of a standalone bill, OR any member of a tab the receipt belongs
    /// to. Gating the full editor on `isSender` alone left tab members
    /// staring at an empty EditSplitView for non-by-items tab receipts.
    private var canFullyEdit: Bool {
        isSender || isTabReceipt
    }

    init(payload: LootMessagePayload, docId: String, receiptImage: UIImage? = nil, onSave: @escaping (LootMessagePayload) -> Void, onCancel: @escaping () -> Void) {
        self.payload = payload
        self.docId = docId
        self.receiptImage = receiptImage
        self.onSave = onSave
        self.onCancel = onCancel

        let (draft, slotPersonIDs) = payload.s.toSplitDraft(
            receiptItems: payload.r.i,
            totalCents: payload.s.tot
        )

        let draftMode = draft.mode
        _mode = State(initialValue: draftMode)
        _payerID = State(initialValue: draft.payerID)

        // --- Recipient self-binding (bug #5: claims AS THE SENDER) --------
        // A first-time claimer is NOT yet bound to any slot — no guest in
        // the wire payload carries their uid, so `isMe` matches nothing and
        // the old code fell back to `active.first` == guest[0] == the
        // sender/payer. Every claim tap was then attributed to the sender
        // ("Karen claiming as Bryan"). Patching the selection default alone
        // didn't hold because auto-open made first-time claiming the common
        // path. Real fix: actually BIND the recipient to a free slot here
        // (set that Person's userId to the local user) so taps, the
        // by-items selection, AND the save round-trip
        // (SplitPayload.from → uid) all resolve to the recipient's own
        // identity. Mirrors the inline path's ensureMySlotBound/claimSlot.
        let localId = KeychainHelper.getOrCreateUserId()
        let isSenderInit = (payload.su.flatMap { $0.isEmpty ? nil : ($0 == localId) }) ?? false

        var boundGuests = draft.guests
        var boundIncluded = draft.includedIDs
        let selectedID: PersonID

        if isSenderInit {
            // Sender keeps the first active guest as the default selection.
            selectedID = draft.includedGuests.first?.id ?? PersonID(rawValue: "")
        } else if let mine = boundGuests.first(where: { $0.isMe(localUserId: localId) }) {
            // Recipient already bound (re-entering via "Modify claimed
            // items") — select their existing slot.
            selectedID = mine.id
        } else if payload.s.cl == true,
                  let freeIdx = boundGuests.firstIndex(where: { ($0.userId ?? "").isEmpty }) {
            // First-time claimer: bind them to the first unclaimed slot. A
            // claimer must be an active participant, so ensure the slot is
            // included.
            boundGuests[freeIdx].userId = localId
            boundIncluded.insert(boundGuests[freeIdx].id)
            selectedID = boundGuests[freeIdx].id
        } else {
            selectedID = draft.includedGuests.first?.id ?? PersonID(rawValue: "")
        }

        _slotPersonIDs = State(initialValue: slotPersonIDs)
        _guests = State(initialValue: boundGuests)
        _includedIDs = State(initialValue: boundIncluded)
        _byItemSelectedGuestID = State(initialValue: selectedID)

        let activeCount = boundGuests.filter { boundIncluded.contains($0.id) }.count

        // Compute initial amounts
        var amounts = draft.perGuestCents
        if draftMode == .equally {
            amounts = splitCentsEvenly(total: payload.s.tot, count: activeCount)
        }
        _guestAmountsCents = State(initialValue: amounts)
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
                // Mode picker — full editor only (standalone-bill sender,
                // or ANY member of a tab the receipt belongs to). A
                // standalone-bill recipient uses this view solely to claim
                // their items (the by-items widget) and can't switch mode.
                if canFullyEdit {
                    splitModePicker()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    Divider().padding(.top, 12)
                }

                // Main content
                ScrollView {
                    VStack(spacing: 16) {
                        // Payer selection + full guest-list editing: full
                        // editor only. A standalone-bill recipient uses this
                        // view solely to claim their OWN items (the by-items
                        // panel) — tab members get the full editor.
                        if canFullyEdit {
                            // Payer selector
                            payerSelector()

                            // Guest list
                            guestListView()
                        }

                        // By-items panel — recipient claims their items here;
                        // sender/tab member assigns items.
                        if mode == .byItems {
                            byItemsPanel()
                        }

                        // Custom-mode remaining — full editor only; a
                        // standalone recipient can't reach custom (no mode
                        // picker for them).
                        if canFullyEdit, mode == .custom {
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
            .navigationTitle(canFullyEdit ? "Edit Split" : "Claim your items")
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
        // Save with ZERO claims == Cancel for a FIRST-TIME claim
        // recipient. P0a eagerly binds them to a free slot on open so
        // taps attribute to them; if they claim nothing and Save, that
        // binding must NOT persist (it would show them as a $0
        // participant — "saving no items should be the same as Cancel,
        // no slot claimed"). Discard the EditSplitView state, broadcast
        // nothing. Returning claimers (already bound in the incoming
        // payload — a deliberate unclaim must persist), the sender, and
        // tab full-editors are explicitly unaffected.
        if !canFullyEdit, payload.s.cl == true {
            let localId = localUserId
            let wasBoundInPayload = payload.s.g.contains { ($0.uid ?? "") == localId }
            let myPID = guests.first(where: { $0.isMe(localUserId: localId) })?.id
            let claimedSomething = myPID.map { pid in
                byItemItems.contains { item in
                    let (_, slots) = SplitEditorViewModel.normalizedPartition(item.partition)
                    return slots.contains(pid)
                }
            } ?? false
            if !wasBoundInPayload, !claimedSomething {
                print("[EditSplit.save] first-time claimer saved zero items → treat as Cancel (no slot bound)")
                onCancel()
                return
            }
        }

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

            if updatedPayload.r.i.isEmpty {
                // Bill was sent without itemization and items were
                // recovered here (re-OCR → Phase 2). The index-map below
                // would no-op against an empty array and the recovered
                // items would be lost — rebuild the wire item list from
                // byItemItems so they (and their partitions) persist.
                updatedPayload.r.i = byItemItems
                    .filter { $0.isComplete }
                    .map { form in
                        let canonical = form.partition.remappingPersonIDs(remap)
                        let wire = canonical.wireFields(guests: wireGuests)
                        return ReceiptItemPayload(
                            id: form.id.uuidString,
                            l: form.label,
                            p: form.priceCents,
                            rs: wire.rs,
                            sh: wire.sh,
                            cu: wire.cu
                        )
                    }
            } else {
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

    @ViewBuilder
    private func byItemsPanel() -> some View {
        let completeItems = byItemItems.filter { $0.isComplete }
        VStack(alignment: .leading, spacing: 10) {
            if completeItems.isEmpty {
                // The bill was sent without itemization. Mirror the
                // compose-side "No items yet" card; with a saved receipt
                // photo a full editor can recover items via re-OCR +
                // Phase 2 (there's no scan transcript post-send).
                byItemsEmptyState()
            } else {
            Text((payload.s.cl ?? false)
                 ? "Tap an item to claim it. Press + to split it."
                 : "Tap items to assign. Unassigned items split evenly between guests.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
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

                    if idx < completeItems.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        // Picker dialog removed — the inline `+` button grows the split
        // one slot at a time, capped at the active guest count.
    }

    /// "No items" card for a bill sent without itemization. A full editor
    /// (sender / tab member) with a saved receipt photo can press "Load
    /// receipt items" to re-OCR the image and run Phase 2 — there's no
    /// scan transcript post-send, so the image is the only recovery
    /// source. Without an image the slot stays a (non-functional)
    /// "Add items to receipt" placeholder: post-send has no Edit Receipt
    /// manual-entry flow. Recipients (claim-only) just see a neutral
    /// message — they can't rewrite the bill's items.
    @ViewBuilder
    private func byItemsEmptyState() -> some View {
        VStack(spacing: 12) {
            if isLoadingItems {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Loading items…")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            } else if !canFullyEdit {
                Text("No items on this receipt yet.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            } else if let err = itemsLoadError, receiptImage != nil {
                Text(err)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: { loadItemsViaOCR() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try again")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            } else if receiptImage != nil {
                Text("No items yet")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Button(action: { loadItemsViaOCR() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.viewfinder")
                        Text("Load receipt items")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            } else {
                // No image post-send: manual add doesn't exist here.
                Text("No items yet")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add items to receipt")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Recover line items for a bill that was sent without itemization:
    /// re-OCR the saved receipt photo and run Phase 2. The bill's totals
    /// stay authoritative (we pass `totalCents` as the known anchor and
    /// never touch `payload.r`/`payload.s` amounts) — this only recovers
    /// the item LIST so it can be split By Items. Recovered items persist
    /// via the rebuilt `r.i` in `save()`.
    private func loadItemsViaOCR() {
        guard canFullyEdit, !isLoadingItems else { return }
        itemsLoadError = nil
        isLoadingItems = true
        Task { @MainActor in
            do {
                // Fetch the photo authoritatively by docId rather than
                // trusting the passed-in `receiptImage`: scanImageCropped
                // isn't cleared between opens, so it can be a stale image
                // from a previously-opened bill. The passed image is only
                // a show/hide hint for the button.
                let (_, fetched) = try await SharedReceiptService.shared.fetch(id: docId)
                guard let image = fetched else {
                    itemsLoadError = "No saved photo for this receipt."
                    isLoadingItems = false
                    return
                }
                let transcript = try await TranscriptGenerator.generate(from: image)
                let phase2 = try await LLMClient.shared.analyzeReceiptPhase2(
                    transcript: transcript,
                    knownTotalCents: totalCents
                )
                let recovered: [LineItemForm] = phase2.items.compactMap { it in
                    guard let cents = it.cents, cents > 0 else { return nil }
                    return LineItemForm(
                        id: UUID(),
                        label: it.label,
                        priceText: Money(cents: cents).inputString,
                        partition: .unclaimed
                    )
                }
                if recovered.isEmpty {
                    itemsLoadError = "No items found on this receipt."
                } else {
                    byItemItems = recovered
                }
                isLoadingItems = false
            } catch {
                print("[EditSplit] re-OCR Phase 2 failed: \(error)")
                itemsLoadError = "Couldn't read items. Try again."
                isLoadingItems = false
            }
        }
    }

    /// "(split N ways)" annotation shown next to an item's price when the
    /// item's partition is multi-way (denominator > 1). Mirrors the
    /// SplitsSummaryView annotation so compose, claim, and edit flows
    /// describe item structure identically.
    private func splitAnnotation(for item: LineItemForm) -> String? {
        let (denom, _) = SplitEditorViewModel.normalizedPartition(item.partition)
        guard denom > 1 else { return nil }
        return "(split \(denom) ways)"
    }

    // MARK: - Partition widget (post-send edit)

    /// The local user's draft PersonID, or nil if they aren't a guest.
    private var myDraftPersonID: PersonID? {
        guests.first(where: { $0.isMe(localUserId: localUserId) })?.id
    }

    /// Who may grow / re-split an item's structure. A full editor (the
    /// standalone-bill sender, or any tab member) always can. A
    /// standalone-bill recipient may only split an UNCLAIMED item, or one
    /// they already own — never one another person has solely claimed
    /// (a finalized item shouldn't sprout a `+` for outsiders).
    private func canChangeItemStructure(slots: [PersonID?]) -> Bool {
        if canFullyEdit { return true }
        guard let owner = slots.compactMap({ $0 }).first else { return true }
        return owner == myDraftPersonID
    }

    @ViewBuilder
    private func partitionRightWidget(for item: LineItemForm) -> some View {
        let (denom, slots) = SplitEditorViewModel.normalizedPartition(item.partition)

        HStack(spacing: 4) {
            if denom < activeCount, canChangeItemStructure(slots: slots) {
                Button {
                    increaseDenominator(itemId: item.id)
                } label: {
                    dottedPlusBadge()
                }
                .buttonStyle(.plain)
            }

            ForEach(0..<denom, id: \.self) { i in
                let claimer = slots.indices.contains(i) ? slots[i] : nil
                Button {
                    togglePartitionShare(itemId: item.id, shareIndex: i)
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
        let fallbackIndex = guests.firstIndex(where: { $0.id == pid }) ?? 0
        let name = guests.first(where: { $0.id == pid }).map { displayName(for: $0) } ?? "Guest"
        ColoredCircleBadge(
            text: BadgeColors.initials(from: name, fallback: fallbackIndex),
            color: colorForGuestId(pid)
        )
    }

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

    @ViewBuilder
    private func dottedPlusBadge() -> some View {
        // Plain `+` glyph, NOT a circle — a circle reads as a tappable claim
        // slot ("assign me here") instead of an "add another slot" action.
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.blue.opacity(0.85))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
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

        let (_, slots) = SplitEditorViewModel.normalizedPartition(byItemItems[idx].partition)
        if let myIdx = slots.firstIndex(of: activeID) {
            togglePartitionShare(itemId: item.id, shareIndex: myIdx)
        } else if let emptyIdx = slots.firstIndex(where: { $0 == nil }) {
            togglePartitionShare(itemId: item.id, shareIndex: emptyIdx)
        }
    }

    /// Grows the item's partition by one slot — capped at activeCount.
    private func increaseDenominator(itemId: UUID) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        let (currentDenom, currentSlots) = SplitEditorViewModel.normalizedPartition(byItemItems[idx].partition)
        guard currentDenom < activeCount else { return }
        byItemItems[idx].partition = .shares(
            denominator: currentDenom + 1,
            slots: currentSlots + [nil]
        )
    }

    /// Per-circle toggle. Treats `.unclaimed` as `shares(1, [nil])` so taps
    /// work on every partition state. Tap filled → unclaim; tap empty →
    /// claim for active (auto-rotate to next un-placed if active is placed).
    private func togglePartitionShare(itemId: UUID, shareIndex: Int) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        let (denom, originalSlots) = SplitEditorViewModel.normalizedPartition(byItemItems[idx].partition)
        guard originalSlots.indices.contains(shareIndex) else { return }

        let activeID = byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }

        var slots = originalSlots
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
        // SINGLE SOURCE OF TRUTH: compute via SplitMath.owedFromDraft — the
        // exact path SplitsSummaryView uses for split.o and ConfirmationView
        // uses for the bill card. Building a parallel formula here is what
        // caused the 1¢ (and earlier 26.47-vs-24.71) desync; share the
        // function instead so Edit Splits is byte-identical to the screen.
        let draftItems: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { SplitDraft.Item(id: $0.id, label: $0.label,
                                   priceCents: $0.priceCents, partition: $0.partition) }
        let draft = SplitDraft(
            guests: guests,
            includedIDs: includedIDs,
            payerID: payerID,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: guestAmountsCents,
            items: draftItems,
            feesCents: payload.s.f ?? 0,
            discountCents: payload.s.d ?? 0,
            taxCents: payload.s.tx ?? 0,
            tipCents: payload.s.tip ?? 0,
            claimMode: payload.s.cl ?? false
        )
        guard let owed = SplitMath.owedFromDraft(
                draft, fallbackTotalCents: totalCents, participantCount: activeCount),
              let idx = guests.firstIndex(where: { $0.id == guestId }),
              owed.indices.contains(idx)
        else { return 0 }
        return owed[idx]
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
