//
//  SplitEditorViewModel.swift
//  Loot
//
//  Owns split-editor state previously held as @State on ConfirmationView and
//  the math/mutation methods previously living in `extension ConfirmationView`
//  (SplitEditorLogic.swift). Phase 4 step 18 of the architectural refactor.
//
//  @FocusState properties (isAmountFieldFocused, guestNameFocusedID) cannot be
//  hosted on an ObservableObject; those stay on ConfirmationView and view
//  methods that need them remain extensions on ConfirmationView. Pure logic
//  and mutation lives here.
//
import Combine
import SwiftUI

@MainActor
final class SplitEditorViewModel: ObservableObject {

    // MARK: - Split panel state
    @Published var mode: SplitDraft.Mode = .equally
    @Published var lastMode: SplitDraft.Mode = .equally
    /// Tap-to-Claim variant of `byItems`: recipients can claim items themselves
    /// in chat. Only meaningful when `mode == .byItems`. Round-trips through
    /// `SplitDraft.claimMode` → `SplitPayload.cl`.
    @Published var claimMode: Bool = false
    @Published var guests: [Person] = []
    @Published var includedIDs: Set<PersonID> = []
    @Published var payerID: PersonID = PersonID(rawValue: "")
    @Published var guestSelectedIndex: Int = 0
    @Published var guestAmountsCents: [Int] = []
    @Published var fineTunerScrollTarget: Int? = nil
    @Published var isEditingAmount: Bool = false
    @Published var editingGuestIndex: Int? = nil
    @Published var amountInputText: String = ""
    @Published var editingGuestNameID: PersonID? = nil
    @Published var byItemItems: [LineItemForm] = []
    @Published var byItemSelectedGuestID: PersonID = PersonID(rawValue: "")
    @Published var feesString: String = ""
    @Published var taxString: String = ""
    @Published var tipString: String = ""
    @Published var didInitByItem: Bool = false
    @Published var confirmed: Bool = true
    @Published var splitModesExpanded: Bool = false
    @Published var splitSnapshot: (mode: SplitDraft.Mode, guests: [Person], includedIDs: Set<PersonID>, payerID: PersonID, guestAmountsCents: [Int])? = nil

    // MARK: - Guest editor (drawer) state
    @Published var showGuestEditor: Bool = false
    @Published var guestEditorMode: GuestEditorMode? = nil
    @Published var draftGuests: [Person] = []
    @Published var draftIncludedIDs: Set<PersonID> = []
    @Published var draftPayerID: PersonID = PersonID(rawValue: "")

    // MARK: - External refs (strong; lifecycle owned by parent view tree)
    let receiptDraftVM: ReceiptDraftViewModel
    let tabContextVM: TabContextViewModel

    // MARK: - Parent callbacks
    var onSelectModeBroadcast: (SplitDraft.Mode) -> Void
    var onGuestsChangedBroadcast: ([Person], Set<PersonID>, PersonID) -> Void

    init(
        receiptDraftVM: ReceiptDraftViewModel,
        tabContextVM: TabContextViewModel,
        onSelectModeBroadcast: @escaping (SplitDraft.Mode) -> Void = { _ in },
        onGuestsChangedBroadcast: @escaping ([Person], Set<PersonID>, PersonID) -> Void = { _, _, _ in }
    ) {
        self.receiptDraftVM = receiptDraftVM
        self.tabContextVM = tabContextVM
        self.onSelectModeBroadcast = onSelectModeBroadcast
        self.onGuestsChangedBroadcast = onGuestsChangedBroadcast
    }

    // MARK: - Derived guest views
    var activeGuests: [Person] { guests.filter { includedIDs.contains($0.id) } }
    var activeCount: Int { max(0, activeGuests.count) }

    var localUserId: String { KeychainHelper.getOrCreateUserId() }

    func allIndex(for id: PersonID) -> Int? {
        guests.firstIndex(where: { $0.id == id })
    }

    func displayName(for guest: Person, fallbackIndexInAllGuests: Int? = nil) -> String {
        let t = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if guest.isMe(localUserId: localUserId) {
            let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            return me.isEmpty ? "Me" : me
        }
        if let idx = fallbackIndexInAllGuests {
            return "Guest \(idx + 1)"
        }
        return "Guest"
    }

    func payerDisplayName() -> String {
        if let idx = guests.firstIndex(where: { $0.id == payerID }) {
            return displayName(for: guests[idx], fallbackIndexInAllGuests: idx)
        }
        if let me = guests.first(where: { $0.isMe(localUserId: localUserId) }) {
            return displayName(for: me)
        }
        let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
        return meName.isEmpty ? "Me" : meName
    }

    func byItemsGuestCents(for guestId: PersonID) -> Int {
        // Sum each item's actual claimed cents for this guest. Reads the
        // partition directly so partial claims (e.g. shares(2, [Me, nil]))
        // give Me half the item's price, not the full price. The legacy
        // `byItemsGuestSubtotalCents` path went through the deduped Set view,
        // which misses partition denominators and produced a "full item per
        // claimer" miscount.
        byItemItems.reduce(0) { acc, item in
            acc + item.partition.centsClaimed(by: guestId, priceCents: item.priceCents)
        }
    }

    func ensureGuestArrays() {
        let cnt = activeCount
        if guestAmountsCents.count != cnt {
            guestAmountsCents = Array(guestAmountsCents.prefix(cnt))
            if guestAmountsCents.count < cnt {
                guestAmountsCents.append(contentsOf: Array(repeating: 0, count: cnt - guestAmountsCents.count))
            }
        }
        if cnt > 0 {
            guestSelectedIndex = min(max(guestSelectedIndex, 0), cnt - 1)
        } else {
            guestSelectedIndex = 0
        }
    }

    func sumBefore(_ idx: Int) -> Int {
        guard idx > 0, guestAmountsCents.count == activeCount else { return 0 }
        return guestAmountsCents.prefix(idx).reduce(0, +)
    }

    func sumThrough(_ idx: Int) -> Int {
        guard guestAmountsCents.count == activeCount else { return 0 }
        return guestAmountsCents.prefix(idx + 1).reduce(0, +)
    }

    func remainingExcluding(_ idx: Int, totalCents: Int) -> Int {
        guard !guestAmountsCents.isEmpty, guestAmountsCents.count == activeCount else { return totalCents }
        let totalAssigned = guestAmountsCents.reduce(0, +)
        let current = guestAmountsCents.indices.contains(idx) ? guestAmountsCents[idx] : 0
        return max(0, totalCents - (totalAssigned - current))
    }

    func percentText(_ cents: Int, totalCents: Int) -> String {
        guard totalCents > 0 else { return "0%" }
        let p = (Double(cents) / Double(totalCents)) * 100
        return String(format: "%.0f%%", p)
    }

    func moneyParts(_ cents: Int) -> (String, String) {
        let absCents = abs(cents)
        let d = absCents / 100
        let c = absCents % 100
        let sign = cents < 0 ? "-" : ""
        return ("\(sign)$\(d).", String(format: "%02d", c))
    }

    // MARK: - Badge colors
    func colorForSlot(_ i: Int) -> Color {
        BadgeColors.color(for: i)
    }

    func colorForGuestId(_ id: PersonID) -> Color {
        guard let idx = guests.firstIndex(where: { $0.id == id }) else {
            return BadgeColors.palette[0]
        }
        return colorForSlot(idx)
    }

    /// Color for a guest at an active-guests index, using their full-array slot.
    func colorForActiveIdx(_ i: Int) -> Color {
        guard activeGuests.indices.contains(i) else { return BadgeColors.palette[0] }
        return colorForGuestId(activeGuests[i].id)
    }

    // MARK: - Guest navigation (for toolbar)
    var currentGuestIndex: Int {
        if mode == .byItems {
            return activeGuests.firstIndex(where: { $0.id == byItemSelectedGuestID }) ?? 0
        } else {
            return guestSelectedIndex
        }
    }

    var currentGuestName: String {
        guard activeCount > 0 else { return "No guests" }
        let idx = currentGuestIndex
        guard activeGuests.indices.contains(idx) else { return "Guest" }
        return displayName(for: activeGuests[idx], fallbackIndexInAllGuests: allIndex(for: activeGuests[idx].id))
    }

    var canGoPrevGuest: Bool {
        currentGuestIndex > 0
    }

    var canGoNextGuest: Bool {
        currentGuestIndex < activeCount - 1
    }

    func selectPreviousGuest() {
        guard canGoPrevGuest else { return }
        let newIndex = currentGuestIndex - 1
        if mode == .byItems {
            byItemSelectedGuestID = activeGuests[newIndex].id
        } else {
            guestSelectedIndex = newIndex
        }
    }

    func selectNextGuest() {
        guard canGoNextGuest else { return }
        let newIndex = currentGuestIndex + 1
        if mode == .byItems {
            byItemSelectedGuestID = activeGuests[newIndex].id
        } else {
            guestSelectedIndex = newIndex
        }
    }

    func lastActiveIndex(idx: Int) -> Int {
        for j in stride(from: idx - 1, through: 0, by: -1) {
            if sumBefore(j) < sumThrough(j) {
                return j
            }
        }
        return 0
    }

    // MARK: - Amount editing
    func startEditingAmount(for guestIndex: Int) {
        guard mode != .byItems else { return }
        if mode == .equally {
            lastMode = mode
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
    }

    func cancelAmountEdit() {
        isEditingAmount = false
        editingGuestIndex = nil
        amountInputText = ""

        if confirmed {
            captureSnapshot()
            confirmed = false
            splitModesExpanded = false
        }
    }

    func updateAmountLive(_ input: String, totalCents: Int) {
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

        let maxAllowed = remainingExcluding(guestIndex, totalCents: totalCents)
        let clampedCents = min(max(newCents, 0), maxAllowed)
        guestAmountsCents[guestIndex] = clampedCents
    }

    // MARK: - By items
    func toggleAssignment(itemId: UUID, totalCents: Int, tipAmount: String) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard byItemItems[idx].isComplete else { return }

        let guestId = byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == guestId }) else { return }

        if byItemItems[idx].assignedGuestIds.contains(guestId) {
            byItemItems[idx].assignedGuestIds.remove(guestId)
        } else {
            byItemItems[idx].assignedGuestIds.insert(guestId)
        }

        // Push the updated assignments through to currentSplitDraft so the
        // ring math, owedAmounts, and outgoing wire payload all see them
        // without requiring an explicit "Save" tap in the split editor.
        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Clears `itemId`'s partition back to `.unclaimed` so the Split button
    /// reappears in the right-side widget. Used by the row tap when an item
    /// is a single full claim (`shares(1, [active])`) and the active guest
    /// taps to release it.
    func clearItemPartition(itemId: UUID, totalCents: Int, tipAmount: String) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        byItemItems[idx].partition = .unclaimed
        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Resets every item's partition to `.unclaimed`. Used by the orphan-ref
    /// scrub when removing a guest. The Tap-to-Claim toggle uses the gentler
    /// `wipeNonSenderItemPartitions` instead so the sender's own pre-claims
    /// aren't lost on an accidental toggle.
    func wipeAllItemPartitions(totalCents: Int, tipAmount: String) {
        for i in byItemItems.indices {
            byItemItems[i].partition = .unclaimed
        }
        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Wipes only OTHER guests' claims from every item's partition, preserving
    /// the sender's own claims. Called when the user flips Tap-to-Claim on so
    /// recipients get a clean slate without erasing the sender's pre-claims to
    /// themselves. Toggling off doesn't restore wiped other-guest claims —
    /// the user can re-assign manually if needed.
    func wipeNonSenderItemPartitions(totalCents: Int, tipAmount: String) {
        let myPID = senderPersonID

        for i in byItemItems.indices {
            switch byItemItems[i].partition {
            case .unclaimed:
                continue
            case .shares(let denom, let slots):
                let cleaned: [PersonID?] = slots.map { pid in
                    pid == myPID ? pid : nil
                }
                if cleaned.allSatisfy({ $0 == nil }) {
                    byItemItems[i].partition = .unclaimed
                } else {
                    byItemItems[i].partition = .shares(denominator: denom, slots: cleaned)
                }
            case .custom(let claims):
                let cleaned = claims.filter { $0.personID == myPID }
                byItemItems[i].partition = cleaned.isEmpty ? .unclaimed : .custom(cleaned)
            }
        }

        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Sender's PersonID — the active guest that's locked-in while
    /// claimMode is on. Returns the local user's slot, falling back to
    /// the payer or the first active guest.
    var senderPersonID: PersonID {
        if let me = activeGuests.first(where: { $0.isMe(localUserId: localUserId) }) {
            return me.id
        }
        if activeGuests.contains(where: { $0.id == payerID }) { return payerID }
        return activeGuests.first?.id ?? payerID
    }

    /// Sets `itemId`'s partition to `.shares(denom, [activeGuest, nil, nil, ...])`
    /// — first slot claimed by the active guest, the rest unclaimed. Used by
    /// the Split button picker to enter explicit shares mode. In claim mode,
    /// the first slot always goes to the sender (regardless of who's active),
    /// preventing accidental pre-assignment to other guests.
    func setItemDenominator(itemId: UUID, denominator: Int, totalCents: Int, tipAmount: String) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard denominator >= 1 else { return }

        let activeID = claimMode ? senderPersonID : byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }

        var slots: [PersonID?] = Array(repeating: nil, count: denominator)
        slots[0] = activeID
        byItemItems[idx].partition = .shares(denominator: denominator, slots: slots)

        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Tap rules on `shareIndex` of `itemId`'s shares partition:
    ///   - Tap a filled slot (own or someone else's) → unclaim it.
    ///   - Tap an empty slot → claim. In normal compose, claims the active
    ///     guest, falling back to the next active guest who isn't yet placed
    ///     (so the second/third tap on empty circles fills with the next
    ///     person automatically). In Tap-to-Claim mode, claims for the
    ///     sender only — never auto-rotates to other guests.
    ///   - The active-guest selector (`byItemSelectedGuestID`) is never
    ///     auto-mutated by this — slot changes don't change who's active.
    ///   - All slots empty → collapse to `.unclaimed` (Split button reappears).
    func togglePartitionShare(itemId: UUID, shareIndex: Int, totalCents: Int, tipAmount: String) {
        guard let idx = byItemItems.firstIndex(where: { $0.id == itemId }) else { return }
        guard case .shares(let denom, var slots) = byItemItems[idx].partition else { return }
        guard slots.indices.contains(shareIndex) else { return }

        let activeID = claimMode ? senderPersonID : byItemSelectedGuestID
        guard activeGuests.contains(where: { $0.id == activeID }) else { return }

        if slots[shareIndex] != nil {
            // Permissive deselect — any filled slot can be unclaimed,
            // regardless of who's active. Lets the user tap a circle to
            // remove that person without first switching the active selector.
            slots[shareIndex] = nil
        } else {
            // Claim. In normal mode: active if free, else next un-placed
            // active guest. In claim mode: sender-only, no auto-rotate.
            let claimer: PersonID? = {
                if !slots.contains(activeID) { return activeID }
                if claimMode { return nil }
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

        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    /// Removes PersonIDs from every byItemItem's partition that no longer
    /// correspond to a guest in `guests`. Called whenever the guest list
    /// changes (add / remove) so partitions can't hold orphaned IDs that
    /// produce "stuck" badges after a guest is removed and re-added.
    func scrubOrphanedPartitionRefs() {
        let validIDs = Set(guests.map(\.id))

        for i in byItemItems.indices {
            switch byItemItems[i].partition {
            case .unclaimed:
                continue
            case .shares(let denom, let slots):
                let cleaned: [PersonID?] = slots.map { pid in
                    guard let p = pid, validIDs.contains(p) else { return nil }
                    return p
                }
                if cleaned.allSatisfy({ $0 == nil }) {
                    byItemItems[i].partition = .unclaimed
                } else {
                    byItemItems[i].partition = .shares(denominator: denom, slots: cleaned)
                }
            case .custom(let claims):
                let cleaned = claims.filter { validIDs.contains($0.personID) }
                byItemItems[i].partition = cleaned.isEmpty ? .unclaimed : .custom(cleaned)
            }
        }
    }

    /// Syncs the current `byItemItems` (form-state) into
    /// `receiptDraftVM.currentSplitDraft.items`, building a draft if none exists.
    /// Called whenever assignments change so the rest of the pipeline
    /// (ring rendering, send) sees up-to-date data without depending on the
    /// split editor's "Save" button.
    func syncByItemsToSplitDraft(totalCents: Int, tipAmount: String) {
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

        if var draft = receiptDraftVM.currentSplitDraft {
            draft.items = items
            // Propagate the Tap-to-Claim flag through every sync, otherwise
            // toggling the switch updates VM state but the live draft (which
            // drives bill-card ring math via `owedFromDraft`) keeps the old
            // claimMode and unclaimed cents get even-split instead of staying
            // unattributed.
            draft.claimMode = claimMode && mode == .byItems
            receiptDraftVM.currentSplitDraft = draft
        } else {
            receiptDraftVM.currentSplitDraft = buildSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
        }
    }

    func seedByItemsFromReceipt() {
        didInitByItem = true

        let receiptItems = receiptDraftVM.currentReceipt?.items ?? []
        byItemItems = receiptItems.map { it in
            LineItemForm(
                id: UUID(),
                label: it.label,
                priceText: Money(cents: it.priceCents).inputString,
                assignedGuestIds: []
            )
        }

        let r = receiptDraftVM.currentReceipt
        feesString = (r?.feesCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.feesCents ?? 0)
        taxString = (r?.taxCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.taxCents ?? 0)
        tipString = (r?.tipCents ?? 0) == 0 ? "" : ReceiptDisplay.money(r?.tipCents ?? 0)
    }

    // MARK: - Mode switching logic
    func selectMode(_ newMode: SplitDraft.Mode, totalCents: Int) {
        lastMode = mode
        mode = newMode

        // Tap-to-Claim is a variant of byItems; switching to any other mode
        // drops the variant flag.
        if newMode != .byItems {
            claimMode = false
        }

        if newMode == .equally {
            ensureGuestArrays()
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: activeCount)
        }

        if newMode == .custom {
            ensureGuestArrays()
            if lastMode == .equally {
                guestAmountsCents = Array(repeating: 0, count: activeCount)
                guestSelectedIndex = 0
            }
        }

        if newMode == .byItems {
            if !didInitByItem { seedByItemsFromReceipt() }
            byItemSelectedGuestID = activeGuests.first?.id ?? PersonID(rawValue: "")
        }

        // Push the mode change through to currentSplitDraft so the ring math
        // and send pipeline use it. Previously this only happened on the
        // explicit "Save" button tap inside the split editor — if a user
        // selected by-items, edited the receipt, then assigned items, the
        // draft's mode would still read .equally and SplitMath would fall
        // through to the wrong branch (assignments silently ignored).
        onSelectModeBroadcast(newMode)
    }

    // MARK: - Build result
    func buildSplitDraft(totalCents: Int, tipAmount: String) -> SplitDraft {
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

        return SplitDraft(
            guests: guests,
            includedIDs: includedIDs,
            payerID: payerID,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: guestAmountsCents,
            items: items,
            feesCents: stringToCents(feesString),
            discountCents: receiptDraftVM.currentReceipt?.discountCents ?? 0,
            taxCents: stringToCents(taxString),
            tipCents: stringToCents(tipString),
            claimMode: claimMode && mode == .byItems
        )
    }

    // MARK: - Guest editor
    func openGuestEditor(_ editorMode: GuestEditorMode) {
        draftGuests = guests
        draftIncludedIDs = includedIDs
        draftPayerID = payerID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            guestEditorMode = editorMode
            showGuestEditor = true
        }
    }

    func applyGuestEdits(totalCents: Int, tipAmount: String) {
        let oldActiveIds = activeGuests.map { $0.id }
        let oldAmounts: [PersonID: Int] = Dictionary(uniqueKeysWithValues: zip(oldActiveIds, guestAmountsCents))

        let newGuests = draftGuests
        let newIncluded = draftIncludedIDs
        let newActive = newGuests.filter { newIncluded.contains($0.id) }

        guests = newGuests
        includedIDs = newIncluded
        payerID = draftPayerID

        if guestSelectedIndex >= newActive.count { guestSelectedIndex = max(0, newActive.count - 1) }

        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        case .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }

        if let first = newActive.first {
            if !newActive.contains(where: { $0.id == byItemSelectedGuestID }) {
                byItemSelectedGuestID = first.id
            }
        }
        let activePersonIDSet = Set(newActive.map { $0.id })
        byItemItems = byItemItems.map { it in
            var copy = it
            copy.assignedGuestIds = copy.assignedGuestIds.intersection(activePersonIDSet)
            return copy
        }
        syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
    }

    // MARK: - Split panel snapshot (for Back button discard)
    func captureSnapshot() {
        splitSnapshot = (
            mode: mode,
            guests: guests,
            includedIDs: includedIDs,
            payerID: payerID,
            guestAmountsCents: guestAmountsCents
        )
    }

    func restoreSnapshot() {
        guard let snap = splitSnapshot else { return }
        mode = snap.mode
        guests = snap.guests
        includedIDs = snap.includedIDs
        payerID = snap.payerID
        guestAmountsCents = snap.guestAmountsCents
        splitSnapshot = nil
    }

    // MARK: - Inline guest management
    func addGuestInline(totalCents: Int) {
        let new = Person.newGuest(displayName: "")

        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        guests.append(new)
        includedIDs.insert(new.id)
        draftGuests = guests
        draftIncludedIDs = includedIDs

        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()
        scrubOrphanedPartitionRefs()
    }

    func removeGuestInline(guestId: PersonID, totalCents: Int) {
        guard let idx = guests.firstIndex(where: { $0.id == guestId }) else { return }
        if activeGuests.count <= 1 { return }
        let hasUid = !((guests[idx].userId ?? "").isEmpty)

        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        if hasUid {
            includedIDs.remove(guestId)
        } else {
            guests.remove(at: idx)
            includedIDs.remove(guestId)
        }
        draftGuests = guests
        draftIncludedIDs = includedIDs

        if payerID == guestId {
            let remaining = activeGuests
            if let me = remaining.first(where: { $0.isMe(localUserId: localUserId) }) { payerID = me.id }
            else if let first = remaining.first { payerID = first.id }
            draftPayerID = payerID
        }

        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()

        if editingGuestNameID == guestId {
            editingGuestNameID = nil
        }

        if guestSelectedIndex >= newActive.count {
            guestSelectedIndex = max(0, newActive.count - 1)
        }
        if !newActive.contains(where: { $0.id == byItemSelectedGuestID }) {
            byItemSelectedGuestID = newActive.first?.id ?? PersonID(rawValue: "")
        }

        scrubOrphanedPartitionRefs()
    }

    func reIncludeGuest(guestId: PersonID, totalCents: Int) {
        guard guests.contains(where: { $0.id == guestId }) else { return }

        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        includedIDs.insert(guestId)
        draftGuests = guests
        draftIncludedIDs = includedIDs

        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()
    }

    // MARK: - Split state initialization (call from onAppear)
    func initializeSplitState(
        splitDraft: SplitDraft?,
        participantCount: Int,
        totalCents: Int
    ) {
        if let existingDraft = splitDraft {
            claimMode = existingDraft.claimMode
        }

        if guests.isEmpty {
            if let existingDraft = splitDraft, !existingDraft.guests.isEmpty {
                guests = existingDraft.guests
                includedIDs = existingDraft.includedIDs
                payerID = existingDraft.payerID
            } else if !draftGuests.isEmpty {
                // onAppear has already seeded draftGuests (with stable PersonIDs
                // for this conversation/tab/fallback). Reuse those PersonIDs
                // verbatim — otherwise this branch would generate a fresh set,
                // and byItemSelectedGuestID (sourced from `guests`) would never
                // match currentSplitDraft.guests (sourced from draftGuests via
                // onGuestsChanged), breaking byItems assignment lookup.
                guests = draftGuests
                includedIDs = draftIncludedIDs
                payerID = draftPayerID
            } else if let tab = tabContextVM.activeTab {
                let myUid = KeychainHelper.getOrCreateUserId()
                let seeded = tab.members.filter { $0.isActive }.map { member -> Person in
                    let uid = (member.userId?.isEmpty == false) ? member.userId! : member.memberId
                    return Person.identified(userId: uid, displayName: member.displayName)
                }
                guests = seeded
                includedIDs = Set(seeded.map(\.id))
                payerID = seeded.first(where: { $0.isMe(localUserId: myUid) })?.id
                    ?? seeded.first?.id
                    ?? PersonID(rawValue: myUid)
            } else {
                let myUid = KeychainHelper.getOrCreateUserId()
                let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                var seeded: [Person] = [Person.identified(userId: myUid, displayName: meName)]
                if participantCount > 1 {
                    for _ in 1..<participantCount {
                        seeded.append(Person.newGuest(displayName: ""))
                    }
                }
                guests = seeded
                includedIDs = Set(seeded.map(\.id))
                payerID = seeded.first?.id ?? PersonID(rawValue: myUid)
            }
        }

        if activeCount > 0 {
            if byItemSelectedGuestID.rawValue.isEmpty {
                byItemSelectedGuestID = activeGuests.first?.id ?? payerID
            }
        }

        ensureGuestArrays()

        if let existingDraft = splitDraft {
            mode = existingDraft.mode
            lastMode = existingDraft.mode

            switch existingDraft.mode {
            case .equally:
                if existingDraft.perGuestCents.count == activeCount {
                    guestAmountsCents = existingDraft.perGuestCents
                } else {
                    guestAmountsCents = splitCentsEvenly(total: totalCents, count: activeCount)
                }

            case .custom:
                if existingDraft.perGuestCents.count == activeCount {
                    guestAmountsCents = existingDraft.perGuestCents
                } else {
                    guestAmountsCents = Array(repeating: 0, count: activeCount)
                }

            case .byItems:
                if !existingDraft.items.isEmpty {
                    didInitByItem = true
                    byItemItems = existingDraft.items.map { it in
                        LineItemForm(
                            id: it.id,
                            label: it.label,
                            priceText: Money(cents: it.priceCents).inputString,
                            assignedGuestIds: Set(it.assignedGuestIds)
                        )
                    }
                } else if !didInitByItem {
                    seedByItemsFromReceipt()
                }
            }
        } else {
            mode = .equally
            lastMode = .equally
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: activeCount)
            if !didInitByItem { seedByItemsFromReceipt() }
        }

        if draftGuests.isEmpty {
            draftGuests = guests
            draftIncludedIDs = includedIDs
            draftPayerID = payerID
        }
    }
}
