//
//  SplitView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//
import SwiftUI

// MARK: - Supporting Types

struct DonutDrag {
    var lastRawFrac: Double
    var endFracUnwrapped: Double
}

// MARK: - Cent Slider (Fine Tuner)

struct CentSlider: View {
    @Binding var cents: Int
    let maxCents: Int
    let color: Color
    let isDraggingDonut: Bool
    @Binding var scrollTarget: Int?

    @State private var dragStartCents: Int? = nil
    @State private var viewWidth: CGFloat = 300
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticCents: Int = 0

    private let pxPerCent: CGFloat = 3.0
    private let majorTickSpacing = 25
    private let labelSpacing = 50

    private var displayOffset: CGFloat {
        -CGFloat(cents) * pxPerCent
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack {
                Canvas { context, size in
                    drawTicks(context: context, size: size, offset: displayOffset)
                }

                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard !isDraggingDonut else { return }

                        if dragStartCents == nil {
                            dragStartCents = cents
                            haptic.prepare()
                        }

                        let startCents = dragStartCents ?? cents
                        let deltaCents = Int(round(-value.translation.width / pxPerCent))
                        let newCents = min(max(startCents + deltaCents, 0), maxCents)

                        if newCents != cents {
                            cents = newCents

                            if abs(newCents - lastHapticCents) >= 25 {
                                haptic.impactOccurred(intensity: 0.4)
                                lastHapticCents = newCents
                            }
                        }
                    }
                    .onEnded { _ in
                        dragStartCents = nil
                        lastHapticCents = cents
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard !isDraggingDonut else { return }

                        let tapX = value.location.x
                        let centerX = width / 2
                        let offsetFromCenter = tapX - centerX
                        let tappedCents = cents + Int(round(offsetFromCenter / pxPerCent))

                        let snappedCents = Int(round(Double(tappedCents) / Double(majorTickSpacing))) * majorTickSpacing
                        let clampedCents = min(max(snappedCents, 0), maxCents)

                        withAnimation(.easeOut(duration: 0.2)) {
                            cents = clampedCents
                        }
                        haptic.impactOccurred(intensity: 0.5)
                        lastHapticCents = clampedCents
                    }
            )
            .onAppear {
                viewWidth = width
                lastHapticCents = cents
            }
            .onChange(of: scrollTarget) { _, newTarget in
                guard let target = newTarget else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    cents = min(max(target, 0), maxCents)
                }
                lastHapticCents = cents
                scrollTarget = nil
            }
            .onChange(of: geo.size.width) { _, newWidth in
                viewWidth = newWidth
            }
        }
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawTicks(context: GraphicsContext, size: CGSize, offset: CGFloat) {
        let trackY = size.height / 2
        let effectiveMax = max(100, maxCents)

        let visibleStartCents = Int(max(0, (-offset - size.width) / pxPerCent))
        let visibleEndCents = Int(min(Double(effectiveMax), (-offset + size.width) / pxPerCent))

        let tickSpacing = 5
        let startTick = max(0, (visibleStartCents / tickSpacing) * tickSpacing)
        for c in stride(from: startTick, through: min(visibleEndCents, effectiveMax), by: tickSpacing) {
            if c % labelSpacing == 0 { continue }

            let x = CGFloat(c) * pxPerCent + offset + size.width / 2
            guard x > -10 && x < size.width + 10 else { continue }

            let isMajor = c % majorTickSpacing == 0
            let tickHeight: CGFloat = isMajor ? 18 : 8
            let tickWidth: CGFloat = isMajor ? 2 : 1
            let opacity: Double = isMajor ? 0.5 : 0.25

            context.fill(
                Path(roundedRect: CGRect(x: x - tickWidth/2, y: trackY - tickHeight/2, width: tickWidth, height: tickHeight), cornerRadius: tickWidth/2),
                with: .color(.primary.opacity(opacity))
            )
        }

        let startLabel = max(0, (visibleStartCents / labelSpacing) * labelSpacing)
        for c in stride(from: startLabel, through: min(visibleEndCents, effectiveMax), by: labelSpacing) {
            let x = CGFloat(c) * pxPerCent + offset + size.width / 2
            guard x > -20 && x < size.width + 20 else { continue }

            let dollars = c / 100
            let cents = c % 100
            let isWholeDollar = cents == 0
            let labelText = isWholeDollar ? "$\(dollars)" : String(format: "$%d.%02d", dollars, cents)

            let fontSize: CGFloat = isWholeDollar ? 13 : 10
            let fontWeight: Font.Weight = isWholeDollar ? .semibold : .medium

            let resolved = context.resolve(Text(labelText).font(.system(size: fontSize, weight: fontWeight)).foregroundColor(.secondary))
            let textSize = resolved.measure(in: size)

            let bgRect = CGRect(
                x: x - textSize.width / 2 - 2,
                y: trackY - textSize.height / 2 - 1,
                width: textSize.width + 4,
                height: textSize.height + 2
            )
            context.fill(Path(roundedRect: bgRect, cornerRadius: 2), with: .color(Color(.systemBackground)))

            context.draw(resolved, at: CGPoint(x: x, y: trackY))
        }
    }
}

// MARK: - ConfirmationView Split Panel Extension

extension ConfirmationView {

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


    private func byItemsGuestCents(for guestId: PersonID) -> Int {
        byItemsGuestSubtotalCents(
            guestID: guestId,
            guestOrder: guests.map(\.id),
            items: byItemItems.map { item in
                (priceCents: item.priceCents, assignedGuestIDs: Array(item.assignedGuestIds))
            }
        )
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

    func remainingExcluding(_ idx: Int) -> Int {
        guard !guestAmountsCents.isEmpty, guestAmountsCents.count == activeCount else { return totalCents }
        let totalAssigned = guestAmountsCents.reduce(0, +)
        let current = guestAmountsCents.indices.contains(idx) ? guestAmountsCents[idx] : 0
        return max(0, totalCents - (totalAssigned - current))
    }

    func percentText(_ cents: Int) -> String {
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
        // Auto-switch from equally → custom, keeping the computed equal amounts intact
        if mode == .equally {
            lastMode = mode
            mode = .custom
            ensureGuestArrays()
            // guestAmountsCents already holds the equal split — keep it
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

    func cancelAmountEdit() {
        isEditingAmount = false
        editingGuestIndex = nil
        amountInputText = ""
        isAmountFieldFocused = false

        // If the confirmation panel was showing, switch to custom split by guest
        if confirmed {
            captureSnapshot()
            confirmed = false
            splitModesExpanded = false
        }
    }

    func updateAmountLive(_ input: String) {
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
        let clampedCents = min(max(newCents, 0), maxAllowed)
        guestAmountsCents[guestIndex] = clampedCents
    }

    // MARK: - By items
    func toggleAssignment(itemId: UUID) {
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
        syncByItemsToSplitDraft()
    }

    /// Syncs the current `byItemItems` (form-state) into
    /// `receiptDraftVM.currentSplitDraft.items`, building a draft if none exists.
    /// Called whenever assignments change so the rest of the pipeline
    /// (ring rendering, send) sees up-to-date data without depending on the
    /// split editor's "Save" button.
    func syncByItemsToSplitDraft() {
        let items: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { it in
                SplitDraft.Item(
                    id: it.id,
                    label: it.label,
                    priceCents: it.priceCents,
                    assignedGuestIds: it.assignedGuestIds.sorted { $0.rawValue < $1.rawValue }
                )
            }

        if var draft = receiptDraftVM.currentSplitDraft {
            draft.items = items
            receiptDraftVM.currentSplitDraft = draft
        } else {
            receiptDraftVM.currentSplitDraft = buildSplitDraft()
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
    func selectMode(_ newMode: SplitDraft.Mode) {
        lastMode = mode
        mode = newMode

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
        onSelectMode(newMode)
    }

    // MARK: - Build result
    func buildSplitDraft() -> SplitDraft {
        let items: [SplitDraft.Item] = byItemItems
            .filter { $0.isComplete }
            .map { it in
                SplitDraft.Item(
                    id: it.id,
                    label: it.label,
                    priceCents: it.priceCents,
                    assignedGuestIds: it.assignedGuestIds.sorted { $0.rawValue < $1.rawValue }
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
            tipCents: stringToCents(tipString)
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

    func applyGuestEdits() {
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
        syncByItemsToSplitDraft()
    }

    // MARK: - Split mode button (for extension use)
    func splitModeButton(_ m: SplitDraft.Mode) -> some View {
        let selected = (m == mode)
        return Button {
            selectMode(m)
            confirmed = false
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
        let selectedCents = guestAmountsCents.indices.contains(guestSelectedIndex)
        ? guestAmountsCents[guestSelectedIndex]
        : 0

        let parts = moneyParts(selectedCents)

        return VStack(alignment: .leading, spacing: 0) {
            splitPanelToolbar()
            
            Spacer(minLength: 0)
            
            GeometryReader { geo in
                let size = min(geo.size.width, 210)
                let lineW: CGFloat = 30
                let radius = size / 2 - lineW / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let handleRadius = radius + lineW / 2

                ZStack {
                    Circle()
                        .stroke(Color(.secondarySystemBackground),
                                style: .init(lineWidth: lineW, lineCap: .round))
                        .frame(width: size, height: size)

                    ForEach(0..<activeCount, id: \.self) { i in
                        if totalCents > 0, guestAmountsCents.count == activeCount {
                            let startFrac = Double(sumBefore(i)) / Double(totalCents)
                            let endFrac = Double(sumThrough(i)) / Double(totalCents)
                            if endFrac > startFrac {
                                Circle()
                                    .trim(from: startFrac, to: endFrac)
                                    .stroke(colorForActiveIdx(i),
                                            style: .init(lineWidth: lineW, lineCap: .round))
                                    .opacity(1)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: size, height: size)
                                    .overlay(
                                        Circle()
                                            .trim(from: startFrac, to: endFrac)
                                            .stroke(Color.black.opacity(0.001),
                                                    style: .init(lineWidth: lineW * 4.5,
                                                                 lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                            .frame(width: size, height: size)
                                        )
                                    .onTapGesture {
                                        guard interactive else { return }
                                        guestSelectedIndex = i
                                    }
                                     }
                            // Show divider circle only if previous guest has amount > $0
                            let colorIdx = lastActiveIndex(idx: i)
                            if i > 0  {
                                let ang = -(.pi / 1.975) + (startFrac * 2 * .pi)
                                let hx = center.x + handleRadius * cos(ang)
                                let hy = center.y + handleRadius * sin(ang)

                                Circle()
                                    .fill(colorForActiveIdx(colorIdx))
                                    .overlay(
                                        Circle().stroke(colorForActiveIdx(colorIdx), lineWidth: 0.05)
                                    )
                                    .frame(width: 30, height: 30)
                                    .position(x: hx, y: hy)
                            }
                        }
                    }

                    if totalCents > 0,
                       guestAmountsCents.count == activeCount,
                       activeCount > 0 {

                        let startFrac = Double(sumBefore(guestSelectedIndex)) / Double(totalCents)
                        let endFrac = Double(sumThrough(guestSelectedIndex)) / Double(totalCents)
                        let handleFrac = max(startFrac, endFrac)
                        let ang = (handleFrac * 2 * .pi) - (.pi / 2)

                        let hx = center.x + handleRadius * cos(ang)
                        let hy = center.y + handleRadius * sin(ang)

                        Circle()
                            .fill(colorForActiveIdx(guestSelectedIndex))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(.white, lineWidth: 5))
                            .position(x: hx, y: hy)
                            .contentShape(Circle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard interactive else { return }
                                        guard totalCents > 0 else { return }

                                        let p = value.location
                                        let dx = p.x - center.x
                                        let dy = p.y - center.y

                                        var a = atan2(dy, dx) + (.pi / 2)
                                        if a < 0 { a += 2 * .pi }
                                        let rawFrac = a / (2 * .pi)

                                        let startFrac = Double(sumBefore(guestSelectedIndex)) / Double(totalCents)
                                        let maxAlloc = remainingExcluding(guestSelectedIndex)
                                        let maxEnd = startFrac + Double(maxAlloc) / Double(totalCents)

                                        if donutDrag == nil {
                                            let curEnd = Double(sumThrough(guestSelectedIndex)) / Double(totalCents)
                                            donutDrag = DonutDrag(lastRawFrac: rawFrac, endFracUnwrapped: curEnd)
                                            haptic.prepare()
                                        }

                                        var d = donutDrag!
                                        var delta = rawFrac - d.lastRawFrac
                                        if delta > 0.5 { delta -= 1 }
                                        if delta < -0.5 { delta += 1 }
                                        d.lastRawFrac = rawFrac
                                        d.endFracUnwrapped += delta

                                        let endClamped = min(max(d.endFracUnwrapped, startFrac), maxEnd)
                                        donutDrag = d

                                        var newCents = Int(round((endClamped - startFrac) * Double(totalCents)))
                                        newCents = min(max(newCents, 0), maxAlloc)
                                        let centsDiff = abs(newCents - lastHapticCents)

                                        if centsDiff >= totalCents/100 {
                                            haptic.impactOccurred(intensity: 7.0)
                                            lastHapticCents = newCents
                                            haptic.prepare()
                                        }

                                        guestAmountsCents[guestSelectedIndex] = newCents
                                    }
                                    .onEnded { _ in
                                        let finalCents = guestAmountsCents.indices.contains(guestSelectedIndex)
                                            ? guestAmountsCents[guestSelectedIndex]
                                            : 0
                                        fineTunerScrollTarget = finalCents
                                        donutDrag = nil
                                    }
                            )
                            .animation(nil, value: handleFrac)
                            .opacity(mode == .equally ? 0 : 1)
                    }

                    VStack(spacing: 4) {
                        let g = activeGuests.indices.contains(guestSelectedIndex) ? activeGuests[guestSelectedIndex] : nil
                        let nm = g.map { displayName(for: $0, fallbackIndexInAllGuests: allIndex(for: $0.id)) } ?? "Guest"
                        Text("\(nm) pays")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(parts.0)
                                .font(.system(size: 30, weight: .bold))
                            Text(parts.1)
                                .font(.system(size: 30, weight: .bold))
                        }
                        .opacity(isEditingAmount && editingGuestIndex == guestSelectedIndex ? 0 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            startEditingAmount(for: guestSelectedIndex)
                        }

                        Text(percentText(selectedCents))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 220)

//            // Fine tuner slider (custom mode only)
//            if interactive {
//                VStack(spacing: 4) {
//                    CentSlider(
//                        cents: Binding(
//                            get: {
//                                guestAmountsCents.indices.contains(guestSelectedIndex)
//                                    ? guestAmountsCents[guestSelectedIndex]
//                                    : 0
//                            },
//                            set: { newValue in
//                                if guestAmountsCents.indices.contains(guestSelectedIndex) {
//                                    guestAmountsCents[guestSelectedIndex] = newValue
//                                }
//                            }
//                        ),
//                        maxCents: remainingExcluding(guestSelectedIndex),
//                        color: colorForActiveIdx(guestSelectedIndex),
//                        isDraggingDonut: donutDrag != nil,
//                        scrollTarget: $fineTunerScrollTarget
//                    )
//                    .padding(.horizontal, 8)
//
//                    Text("Slide to fine-tune amount")
//                        .font(.system(size: 11))
//                        .foregroundColor(.secondary)
//                }
//                .padding(.top, 4)
//            }
            
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
                Text("Select a guest, then tap an item to assign/unassign them.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

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
                } else if byItemItems.filter({ $0.isComplete }).isEmpty {
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
                            ForEach(byItemItems.indices, id: \.self) { idx in
                                let item = byItemItems[idx]

                                if item.isComplete {
                                    let isLast = idx == byItemItems.filter({ $0.isComplete }).count - 1

                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.label)
                                                .font(.system(size: 16, weight: .semibold))
                                                .lineLimit(1)
                                            Text(ReceiptDisplay.money(item.priceCents))
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        HStack(spacing: 6) {
                                            ForEach(item.assignedGuestIds.sorted { $0.rawValue < $1.rawValue }, id: \.self) { gid in
                                                let fallbackIndex = guests.firstIndex(where: { $0.id == gid }) ?? 0
                                                let name = guests.first(where: { $0.id == gid }).map { displayName(for: $0, fallbackIndexInAllGuests: fallbackIndex) } ?? "Guest"
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
                                    .onTapGesture {
                                        toggleAssignment(itemId: item.id)
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

    // MARK: - Split panel toolbar (Back / Save)
    func splitPanelToolbar() -> some View {
        HStack {
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                restoreSnapshot()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    confirmed = true
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
                let draft = buildSplitDraft()
                receiptDraftVM.currentSplitDraft = draft
                onSelectMode(mode)
                onGuestsChanged(guests, includedIDs, payerID)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    confirmed = true
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
//            Text("Split Method")
//                .font(.system(size: 14, weight: .regular))
//                .foregroundColor(.secondary)
//                .padding(.top, 10)
//                .padding(.bottom, 7)
            HStack(spacing: 12) {
                ForEach(modes, id: \.1) { (m, label) in
                    Button {
                        if capturesSnapshot { captureSnapshot() }
                        if closesExpanded {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                splitModesExpanded = false
                            }
                        }
                        selectMode(m)
                        onRequestExpand()
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        confirmed = false
                    } label: {
                        Text(label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(mode == m ? .white : .primary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 18).fill(mode == m ? .blue : buttonBase))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: - Inline guest management

    func addGuestInline() {
        let new = Person.newGuest(displayName: "")

        // Snapshot old amounts by guest ID
        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        guests.append(new)
        includedIDs.insert(new.id)
        draftGuests = guests
        draftIncludedIDs = includedIDs

        // Rebuild amounts
        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()
    }

    func removeGuestInline(guestId: PersonID) {
        guard let idx = guests.firstIndex(where: { $0.id == guestId }) else { return }
        // Block if this is the last included guest
        if activeGuests.count <= 1 { return }
        let hasUid = !((guests[idx].userId ?? "").isEmpty)

        // Snapshot old amounts by guest ID
        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        if hasUid {
            // Exclude (recoverable) — guest stays in array, just out of includedIDs
            includedIDs.remove(guestId)
        } else {
            // Permanently delete guests without a uid
            guests.remove(at: idx)
            includedIDs.remove(guestId)
        }
        draftGuests = guests
        draftIncludedIDs = includedIDs

        // Reassign payer if removed/excluded
        if payerID == guestId {
            let remaining = activeGuests
            if let me = remaining.first(where: { $0.isMe(localUserId: localUserId) }) { payerID = me.id }
            else if let first = remaining.first { payerID = first.id }
            draftPayerID = payerID
        }

        // Rebuild amounts
        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()

        // Clear editing state if needed
        if editingGuestNameID == guestId {
            editingGuestNameID = nil
            guestNameFocusedID = nil
        }

        // Fix selection indices
        if guestSelectedIndex >= newActive.count {
            guestSelectedIndex = max(0, newActive.count - 1)
        }
        if !newActive.contains(where: { $0.id == byItemSelectedGuestID }) {
            byItemSelectedGuestID = newActive.first?.id ?? PersonID(rawValue: "")
        }
    }

    func reIncludeGuest(guestId: PersonID) {
        guard guests.contains(where: { $0.id == guestId }) else { return }

        // Snapshot old amounts by guest ID
        let oldActive = activeGuests
        let oldAmounts: [PersonID: Int] = Dictionary(
            uniqueKeysWithValues: zip(oldActive.map(\.id), guestAmountsCents.prefix(oldActive.count))
        )

        includedIDs.insert(guestId)
        draftGuests = guests
        draftIncludedIDs = includedIDs

        // Rebuild amounts
        let newActive = activeGuests
        switch mode {
        case .equally:
            guestAmountsCents = splitCentsEvenly(total: totalCents, count: newActive.count)
        case .custom, .byItems:
            // Re-included guest gets 0 — user must manually assign in custom/byItems
            guestAmountsCents = newActive.map { oldAmounts[$0.id] ?? 0 }
        }
        ensureGuestArrays()
    }

    // MARK: - Shared guest list (used by all split modes)
    func guestList() -> some View {
        VStack(spacing: 8) {
            // "Paid by [Name]" payer selector
            HStack(spacing: 4) {
                Text("Paid by")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                Menu {
                    ForEach(activeGuests) { guest in
                        Button {
                            payerID = guest.id
                            draftPayerID = guest.id
                        } label: {
                            HStack {
                                Text(displayName(for: guest, fallbackIndexInAllGuests: allIndex(for: guest.id)))
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
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            ScrollView {
//                VStack{
                    // Guest rows
                    ForEach(0..<activeCount, id: \.self) { i in
                        let guest = activeGuests[i]
                        let gid = guest.id
                        let isSelected: Bool = mode == .byItems
                        ? gid == byItemSelectedGuestID
                        : i == guestSelectedIndex
                        
                        HStack(spacing: 8) {
                            // Badge – tap to select guest
                            ColoredCircleBadge(
                                text: BadgeColors.initials(
                                    from: displayName(for: guest, fallbackIndexInAllGuests: allIndex(for: gid)),
                                    fallback: allIndex(for: gid) ?? i
                                ),
                                color: colorForActiveIdx(i)
                            )
                            .onTapGesture {
                                if mode == .byItems { byItemSelectedGuestID = gid }
                                else { guestSelectedIndex = i }
                            }

                            // Name – tap to edit inline (disabled for tab members)
                            let isMe = guest.isMe(localUserId: localUserId)
                            let isTabMember = uiModel.activeTab != nil && guest.userId != nil && !guest.userId!.isEmpty
                            let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if editingGuestNameID == gid && !isMe && !isTabMember {
                                TextField(
                                    "Guest name",
                                    text: Binding(
                                        get: {
                                            guests.first(where: { $0.id == gid })?.displayName ?? ""
                                        },
                                        set: { newValue in
                                            if let idx = guests.firstIndex(where: { $0.id == gid }) {
                                                guests[idx].displayName = newValue
                                                draftGuests = guests
                                            }
                                        }
                                    )
                                )
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                .focused($guestNameFocusedID, equals: gid)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit {
                                    editingGuestNameID = nil
                                }
                            } else {
                                let isUnnamed = trimmed.isEmpty && !isMe
                                Text(displayName(for: guest, fallbackIndexInAllGuests: allIndex(for: gid)))
                                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isUnnamed ? .secondary : .primary)
                                    .onTapGesture {
                                        if !isMe && !isTabMember {
                                            editingGuestNameID = gid
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                guestNameFocusedID = gid
                                            }
                                        }
                                    }
                            }
                            
                            Spacer()
                            
                            // Right side: amount (byItems shows running total; other modes show editable amount)
                            if mode == .byItems {
                                let guestCents = byItemsGuestCents(for: gid)
                                Text(ReceiptDisplay.money(guestCents))
                                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(guestCents > 0 ? .primary : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color(.tertiarySystemFill) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text(ReceiptDisplay.money(guestAmountsCents.indices.contains(i) ? guestAmountsCents[i] : 0))
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(mode != .byItems ? Color(.tertiarySystemFill) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if mode != .byItems {
                                            startEditingAmount(for: i)
                                        }
                                    }
                            }
                            
                            // Remove/exclude button (hidden when only one included guest remains)
                            if activeCount > 1 {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        removeGuestInline(guestId: gid)
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
//                }
            }
            .frame(maxHeight: 230)
            .defaultScrollAnchor(.bottom)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Custom mode remaining
            if mode == .custom {
                let remaining = max(0, totalCents - guestAmountsCents.reduce(0, +))
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
            if uiModel.activeTab == nil {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        addGuestInline()
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
            let excludedWithUid = guests.filter { !includedIDs.contains($0.id) && !(($0.userId ?? "").isEmpty) }
            if !excludedWithUid.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not Included")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    ForEach(excludedWithUid) { guest in
                        HStack(spacing: 8) {
                            ColoredCircleBadge(
                                text: BadgeColors.initials(from: displayName(for: guest, fallbackIndexInAllGuests: allIndex(for: guest.id)), fallback: allIndex(for: guest.id) ?? 0),
                                color: colorForGuestId(guest.id)
                            )
                            Text(displayName(for: guest, fallbackIndexInAllGuests: allIndex(for: guest.id)))
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    reIncludeGuest(guestId: guest.id)
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
                editingGuestNameID = nil
            }
        }
    }

    // MARK: - Guest navigation toolbar
    func guestNavigationToolbar() -> some View {
        HStack(spacing: 0) {
            Button(action: selectPreviousGuest) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canGoPrevGuest ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevGuest)

            Spacer()

            HStack(spacing: 8) {
                Text(currentGuestName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: selectNextGuest) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canGoNextGuest ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNextGuest)
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

    // MARK: - Split state initialization (call from onAppear)
    func initializeSplitState() {
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
            } else if let tab = uiModel.activeTab {
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

    // MARK: - Amount editing overlay
    @ViewBuilder
    func amountEditingOverlay() -> some View {
        if isEditingAmount, let guestIndex = editingGuestIndex {
            VStack(spacing: 12) {
                if activeGuests.indices.contains(guestIndex) {
                    Text(displayName(for: activeGuests[guestIndex], fallbackIndexInAllGuests: allIndex(for: activeGuests[guestIndex].id)))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .center, spacing: 2) {
                    Text("$")
                        .font(.system(size: 32, weight: .bold))
                    TextField("0", text: $amountInputText)
                        .font(.system(size: 32, weight: .bold))
                        .keyboardType(.decimalPad)
                        .focused($isAmountFieldFocused)
                        .multilineTextAlignment(.leading)                        .fixedSize()
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
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22))
        }
    }
}
